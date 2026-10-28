using System.Reflection;
using UAssetAPI;
using UAssetAPI.ExportTypes;
using UAssetAPI.FieldTypes;
using UAssetAPI.Kismet.Bytecode;
using UAssetAPI.Kismet.Bytecode.Expressions;
using UAssetAPI.UnrealTypes;
using UAssetAPI.Unversioned;

// helpers for patching cooked blueprints: adding variables and splicing kismet bytecode
public static class BlueprintPatching {
    // Adds a variable to a blueprint class, cloned from one of its existing variables.
    // Only use this for classes that are never subclassed or placed in other packages: unversioned properties index the class's own
    // properties before the inherited ones, so a new variable shifts the indices of every inherited property. The CDO in this asset
    // is re-serialized with the updated schema, anything serialized elsewhere against the old schema would break.
    public static FProperty AddVariable(UAsset asset, string className, string templateVariable, string name, EPropertyFlags extraFlags = 0) {
        var cls = (ClassExport)asset[className];
        if (cls.LoadedProperties.Any(p => p.Name.ToString() == name))
            throw new Exception($"{className} already has {name}");
        var variable = CloneProperty(cls.LoadedProperties.First(p => p.Name.ToString() == templateVariable), asset.Name(name));
        variable.PropertyFlags |= extraFlags;
        cls.LoadedProperties = [..cls.LoadedProperties, variable];

        var mappings = asset.Mappings ?? throw new Exception($"{className} requires mappings");
        var updated = 0;
        foreach (var key in mappings.Schemas.Keys.ToList()) {
            if (mappings.Schemas[key].Name != className)
                continue;
            var schema = Usmap.GetSchemaFromStructExport(cls, mappings.AreFNamesCaseInsensitive);
            schema.ModulePath = mappings.Schemas[key].ModulePath;
            mappings.Schemas[key] = schema;
            updated++;
        }
        if (updated == 0)
            throw new Exception($"No schema registered for {className}, its CDO would be written with the old property indices");
        asset.SyncNamesReferencedFromExportDataCount();
        return variable;
    }

    // Replaces removeCount statements starting at func.ScriptBytecode[index] with the given statements and fixes up all code offsets.
    // Jumps to the splice point land on the new statements. Every EX_JumpIfNot among the new statements is pointed at skipTarget:
    // either the first statement after the new ones (true) or the original statement index given.
    public static void Splice(UAsset asset, FunctionExport func, int index, int removeCount, KismetExpression[] statements, object? skipTarget = null) {
        var offsets = StatementOffsets(asset, func.ScriptBytecode);
        var start = offsets[index];
        var oldEnd = offsets[index + removeCount];

        // computed jumps (ubergraphs) are entered at offsets stored in other functions and latent actions, which can't be relocated;
        // switch values store absolute offsets inside their own statement, so they must not move
        for (var i = 0; i < func.ScriptBytecode.Length; i++) {
            var movesWithSplice = i >= index;
            uint visitOffset = 0;
            func.ScriptBytecode[i].Visit(asset, ref visitOffset, (expression, _) => {
                if (expression is EX_ComputedJump || (expression is EX_SwitchValue && movesWithSplice))
                    throw new Exception($"{func.ObjectName}: {expression.GetType().Name} is not supported when splicing at statement {index}");
            });
        }

        var size = (uint)statements.Sum(s => ExpressionSize(asset, s));
        var target = skipTarget switch {
            true => start + size,
            int originalIndex when originalIndex >= index + removeCount => offsets[originalIndex] - oldEnd + start + size,
            int => throw new Exception("skipTarget must point past the replaced statements"),
            _ => (uint?)null
        };
        if (target != null)
            foreach (var jump in statements.OfType<EX_JumpIfNot>())
                jump.CodeOffset = target.Value;

        uint Relocate(uint offset) {
            if (offset <= start)
                return offset;
            if (offset < oldEnd)
                throw new Exception($"{func.ObjectName}: a jump targets a replaced statement");
            return offset - oldEnd + start + size;
        }

        foreach (var statement in func.ScriptBytecode) {
            switch (statement) {
                case EX_Jump jump: jump.CodeOffset = Relocate(jump.CodeOffset); break;
                case EX_JumpIfNot jump: jump.CodeOffset = Relocate(jump.CodeOffset); break;
                case EX_Skip skip: skip.CodeOffset = Relocate(skip.CodeOffset); break;
                case EX_PushExecutionFlow push: push.PushingAddress = Relocate(push.PushingAddress); break;
            }
        }
        func.ScriptBytecode = [..func.ScriptBytecode[..index], ..statements, ..func.ScriptBytecode[(index + removeCount)..]];
    }

    public static uint[] StatementOffsets(UAsset asset, KismetExpression[] code) {
        var offsets = new uint[code.Length + 1];
        for (var i = 0; i < code.Length; i++)
            offsets[i + 1] = offsets[i] + (uint)ExpressionSize(asset, code[i]);
        return offsets;
    }

    // obj->function(...) for a function without return value, where call is the EX_FinalFunction/EX_VirtualFunction;
    // failSilent skips the call without logging "Accessed None" when obj is null
    public static EX_Context CallOn(UAsset asset, KismetExpression obj, KismetExpression call, bool failSilent = false) {
        var context = failSilent ? new EX_Context_FailSilent() : new EX_Context();
        context.ObjectExpression = obj;
        context.Offset = (uint)ExpressionSize(asset, call);
        context.RValuePointer = new KismetPropertyPointer { New = new FFieldPath { Path = [], ResolvedOwner = FPackageIndex.FromRawIndex(0) } };
        context.ContextExpression = call;
        return context;
    }

    static int ExpressionSize(UAsset asset, KismetExpression expression) {
        using var stream = new MemoryStream();
        using var writer = new AssetBinaryWriter(stream, asset);
        return ExpressionSerializer.WriteExpression(expression, writer);
    }

    // copies all public fields of an FProperty (all of its serialized state) under a new name
    public static T CloneProperty<T>(T source, FName name) where T : FProperty {
        var clone = (T)Activator.CreateInstance(source.GetType())!;
        foreach (var field in source.GetType().GetFields(BindingFlags.Public | BindingFlags.Instance))
            field.SetValue(clone, field.GetValue(source));
        clone.Name = name;
        return clone;
    }

    public static KismetPropertyPointer PropertyPointer(FName name, FPackageIndex owner) => new() { New = new FFieldPath { Path = [name], ResolvedOwner = owner } };

    // object->variable, where object is any object-valued expression
    public static EX_Context MemberOf(KismetExpression obj, KismetPropertyPointer variable) => new() {
        ObjectExpression = obj,
        Offset = 9, // size of EX_InstanceVariable
        RValuePointer = variable,
        ContextExpression = new EX_InstanceVariable { Variable = variable }
    };
}

public static class UAssetExtensions {
    public static FName Name(this UAsset asset, string name) => new(asset, asset.AddNameReference(new FString(name)));

    public static FPackageIndex ExportIndex(this UAsset asset, string name) => FPackageIndex.FromExport(asset.Exports.IndexOf(asset[name]));

    public static FPackageIndex? TryFindImport(this UAsset asset, string objectName, string? className = null, FPackageIndex? outer = null) {
        for (var i = 0; i < asset.Imports.Count; i++) {
            var import = asset.Imports[i];
            if (import.ObjectName.ToString() == objectName && (className == null || import.ClassName.ToString() == className) &&
                (outer == null || import.OuterIndex.Index == outer.Index))
                return FPackageIndex.FromImport(i);
        }
        return null;
    }

    public static FPackageIndex FindImport(this UAsset asset, string objectName, string? className = null, FPackageIndex? outer = null) =>
        asset.TryFindImport(objectName, className, outer) ?? throw new Exception($"Missing import {objectName}");

    public static FPackageIndex FindOrAddImport(this UAsset asset, string classPackage, string className, FPackageIndex outer, string objectName) =>
        asset.TryFindImport(objectName, className, outer) ?? asset.AddImport(new Import(classPackage, className, outer, objectName, false, asset));

    // a native function (e.g. KismetMathLibrary::SelectInt) of an imported script class
    public static FPackageIndex FindOrAddFunctionImport(this UAsset asset, FPackageIndex scriptClass, string functionName) =>
        asset.FindOrAddImport("/Script/CoreUObject", "Object", scriptClass, functionName);

    // a blueprint class of the mod, e.g. ("/Game/Coop/CoopConfig", "CoopConfig_C")
    public static FPackageIndex FindOrAddBlueprintClassImport(this UAsset asset, string packagePath, string className) =>
        asset.FindOrAddImport("/Script/Engine", "BlueprintGeneratedClass",
            asset.FindOrAddImport("/Script/CoreUObject", "Package", FPackageIndex.FromRawIndex(0), packagePath), className);

    // retoc uses this count when converting to zen; names added after loading must be included
    public static void SyncNamesReferencedFromExportDataCount(this UAsset asset) =>
        typeof(UAsset).GetField("NamesReferencedFromExportDataCount", BindingFlags.NonPublic | BindingFlags.Instance)!
            .SetValue(asset, asset.GetNameMapIndexList().Count);
}
