using UAssetAPI;
using UAssetAPI.ExportTypes;
using UAssetAPI.FieldTypes;
using UAssetAPI.Kismet.Bytecode;
using UAssetAPI.Kismet.Bytecode.Expressions;
using UAssetAPI.UnrealTypes;
using UAssetAPI.Unversioned;

// After a battle the exploration controller (player controller 0) used to be handed back to the primary user (player 1).
// These patches remember which user controlled the exploration character when the battle started and give control back to that user afterwards.
public static class ControlRestorePatch {
    const string VariableName = "CoopExplorationUserId";

    // adds the CoopController_C::CoopExplorationUserId variable, cloned from Tmp_UserId (FPlatformUserId)
    public static void PatchCoopController(UAsset coopController) {
        var cls = (ClassExport)coopController["CoopController_C"];
        if (cls.LoadedProperties.Any(p => p.Name.ToString() == VariableName))
            throw new Exception($"CoopController already has {VariableName}");
        var tmpUserId = (FStructProperty)cls.LoadedProperties.First(p => p.Name.ToString() == "Tmp_UserId");
        var variable = new FStructProperty {
            Struct = tmpUserId.Struct,
            ArrayDim = tmpUserId.ArrayDim,
            ElementSize = tmpUserId.ElementSize,
            PropertyFlags = tmpUserId.PropertyFlags,
            RepIndex = tmpUserId.RepIndex,
            RepNotifyFunc = tmpUserId.RepNotifyFunc,
            BlueprintReplicationCondition = tmpUserId.BlueprintReplicationCondition,
            SerializedType = tmpUserId.SerializedType,
            Flags = tmpUserId.Flags,
            Name = new FName(coopController, coopController.AddNameReference(new FString(VariableName)))
        };
        cls.LoadedProperties = [..cls.LoadedProperties, variable];

        // unversioned properties index the class's own properties before the inherited ones, so adding a variable shifts
        // the indices of every inherited property; the CDO has to be re-serialized with the updated schema
        var mappings = coopController.Mappings ?? throw new Exception("CoopController requires mappings");
        var schema = Usmap.GetSchemaFromStructExport(cls, mappings.AreFNamesCaseInsensitive);
        foreach (var key in mappings.Schemas.Keys.ToList()) {
            if (mappings.Schemas[key].Name != cls.ObjectName.ToString())
                continue;
            schema.ModulePath = mappings.Schemas[key].ModulePath;
            mappings.Schemas[key] = schema;
        }
        FixNamesReferencedFromExportDataCount(coopController);
    }

    // stores the controlling user in PrepareCharacterForBattle and restores it in ResumeExplorationOnBattleEnd
    public static void PatchControllerWorld(UAsset controllerWorld) {
        var gameplayStatics = FindImport(controllerWorld, "GameplayStatics", "Class");
        var playerController = FindImport(controllerWorld, "PlayerController", "Class");
        var getPlayerController = FindImport(controllerWorld, "GetPlayerController", outer: gameplayStatics);
        var setPlayerPlatformUserId = FindImport(controllerWorld, "SetPlayerPlatformUserId", outer: gameplayStatics);
        var getPlatformUserId = FindOrAddImport(controllerWorld, "/Script/CoreUObject", "Object", playerController, "GetPlatformUserId");
        var coopControllerPackage = FindOrAddImport(controllerWorld, "/Script/CoreUObject", "Package", FPackageIndex.FromRawIndex(0), "/Game/Coop/CoopController");
        var coopControllerClass = FindOrAddImport(controllerWorld, "/Script/Engine", "BlueprintGeneratedClass", coopControllerPackage, "CoopController_C");
        var variableName = new FName(controllerWorld, controllerWorld.AddNameReference(new FString(VariableName)));

        KismetPropertyPointer VariablePointer() => new() { New = new FFieldPath { Path = [variableName], ResolvedOwner = coopControllerClass } };

        // Cast<CoopController_C>(GetPlayerController(self, 1))->CoopExplorationUserId
        // player controller 1 is the first CoopController, which exists for the whole map; if it doesn't, the context fails and the value is cleared
        EX_Context CoopVariable() => new() {
            ObjectExpression = new EX_DynamicCast {
                ClassPtr = coopControllerClass,
                Target = new EX_CallMath { StackNode = getPlayerController, Parameters = [new EX_Self(), new EX_IntConst { Value = 1 }] }
            },
            Offset = 9, // size of EX_InstanceVariable
            RValuePointer = VariablePointer(),
            ContextExpression = new EX_InstanceVariable { Variable = VariablePointer() }
        };

        // PrepareCharacterForBattle: CoopController->CoopExplorationUserId = self->GetPlatformUserId()
        {
            var func = (FunctionExport)controllerWorld["PrepareCharacterForBattle"];
            KismetExpression store = new EX_Let {
                Value = VariablePointer(),
                Variable = CoopVariable(),
                Expression = new EX_FinalFunction { StackNode = getPlatformUserId, Parameters = [] }
            };
            InsertStatements(controllerWorld, func, 0, [store]);
        }

        // ResumeExplorationOnBattleEnd: after resetting to the primary user, swap the stored user back onto player controller 0
        {
            var func = (FunctionExport)controllerWorld["ResumeExplorationOnBattleEnd"];
            var resetIndex = Array.FindIndex(func.ScriptBytecode, e => e is EX_CallMath call && call.StackNode.Index == setPlayerPlatformUserId.Index);
            if (resetIndex < 0)
                throw new Exception("ResumeExplorationOnBattleEnd: SetPlayerPlatformUserId call not found");
            var reset = (EX_CallMath)func.ScriptBytecode[resetIndex];
            KismetExpression restore = new EX_CallMath {
                StackNode = setPlayerPlatformUserId,
                Parameters = [reset.Parameters[0], CoopVariable()]
            };
            InsertStatements(controllerWorld, func, resetIndex + 1, [restore]);
        }

        FixNamesReferencedFromExportDataCount(controllerWorld);
    }

    // inserts statements and shifts all code offsets after the insertion point
    static void InsertStatements(UAsset asset, FunctionExport func, int index, KismetExpression[] statements) {
        var insertAt = StatementOffsets(asset, func.ScriptBytecode)[index];
        var size = (uint)statements.Sum(s => ExpressionSize(asset, s));
        foreach (var statement in func.ScriptBytecode) {
            switch (statement) {
                case EX_Jump jump when jump.CodeOffset >= insertAt: jump.CodeOffset += size; break;
                case EX_JumpIfNot jump when jump.CodeOffset >= insertAt: jump.CodeOffset += size; break;
                case EX_Skip skip when skip.CodeOffset >= insertAt: skip.CodeOffset += size; break;
                case EX_PushExecutionFlow push when push.PushingAddress >= insertAt: push.PushingAddress += size; break;
                case EX_ComputedJump: throw new Exception($"{func.ObjectName}: computed jumps are not supported");
            }
        }
        func.ScriptBytecode = [..func.ScriptBytecode[..index], ..statements, ..func.ScriptBytecode[index..]];
    }

    static uint[] StatementOffsets(UAsset asset, KismetExpression[] code) {
        var offsets = new uint[code.Length + 1];
        for (var i = 0; i < code.Length; i++)
            offsets[i + 1] = offsets[i] + (uint)ExpressionSize(asset, code[i]);
        return offsets;
    }

    static int ExpressionSize(UAsset asset, KismetExpression expression) {
        using var stream = new MemoryStream();
        using var writer = new AssetBinaryWriter(stream, asset);
        return ExpressionSerializer.WriteExpression(expression, writer);
    }

    static FPackageIndex FindImport(UAsset asset, string objectName, string? className = null, FPackageIndex? outer = null) {
        for (var i = 0; i < asset.Imports.Count; i++) {
            var import = asset.Imports[i];
            if (import.ObjectName.ToString() == objectName && (className == null || import.ClassName.ToString() == className) &&
                (outer == null || import.OuterIndex.Index == outer.Index))
                return FPackageIndex.FromImport(i);
        }
        throw new Exception($"Missing import {objectName}");
    }

    static FPackageIndex FindOrAddImport(UAsset asset, string classPackage, string className, FPackageIndex outer, string objectName) {
        try {
            return FindImport(asset, objectName, className, outer);
        } catch {
            return asset.AddImport(new Import(classPackage, className, outer, objectName, false, asset));
        }
    }

    static void FixNamesReferencedFromExportDataCount(UAsset asset) {
        typeof(UAsset).GetField("NamesReferencedFromExportDataCount", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)!
            .SetValue(asset, asset.GetNameMapIndexList().Count);
    }
}
