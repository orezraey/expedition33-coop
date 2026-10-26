using System.Reflection;
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
        var tmpUserId = cls.LoadedProperties.First(p => p.Name.ToString() == "Tmp_UserId");
        cls.LoadedProperties = [..cls.LoadedProperties, CloneProperty(tmpUserId, coopController.Name(VariableName))];

        // unversioned properties index the class's own properties before the inherited ones, so adding a variable shifts
        // the indices of every inherited property; the CDO has to be re-serialized with the updated schema
        var mappings = coopController.Mappings ?? throw new Exception("CoopController requires mappings");
        foreach (var key in mappings.Schemas.Keys.ToList()) {
            if (mappings.Schemas[key].Name != cls.ObjectName.ToString())
                continue;
            var schema = Usmap.GetSchemaFromStructExport(cls, mappings.AreFNamesCaseInsensitive);
            schema.ModulePath = mappings.Schemas[key].ModulePath;
            mappings.Schemas[key] = schema;
        }
        coopController.SyncNamesReferencedFromExportDataCount();
    }

    // stores the controlling user when a battle begins and restores it in ResumeExplorationOnBattleEnd
    public static void PatchControllerWorld(UAsset controllerWorld) {
        var gameplayStatics = controllerWorld.FindImport("GameplayStatics", "Class");
        var playerController = controllerWorld.FindImport("PlayerController", "Class");
        var kismetMathLibrary = controllerWorld.FindImport("KismetMathLibrary", "Class");
        var kismetSystemLibrary = controllerWorld.FindImport("KismetSystemLibrary", "Class");
        var getPlayerController = controllerWorld.FindImport("GetPlayerController", outer: gameplayStatics);
        var setPlayerPlatformUserId = controllerWorld.FindImport("SetPlayerPlatformUserId", outer: gameplayStatics);
        var notPreBool = controllerWorld.FindImport("Not_PreBool", outer: kismetMathLibrary);
        var isValid = controllerWorld.FindImport("IsValid", outer: kismetSystemLibrary);
        var getPlatformUserId = controllerWorld.FindOrAddImport("/Script/CoreUObject", "Object", playerController, "GetPlatformUserId");
        var coopControllerPackage = controllerWorld.FindOrAddImport("/Script/CoreUObject", "Package", FPackageIndex.FromRawIndex(0), "/Game/Coop/CoopController");
        var coopControllerClass = controllerWorld.FindOrAddImport("/Script/Engine", "BlueprintGeneratedClass", coopControllerPackage, "CoopController_C");
        var isInBattle = FPackageIndex.FromExport(controllerWorld.Exports.IndexOf(controllerWorld["IsInBattle"]));
        var variableName = controllerWorld.Name(VariableName);

        KismetPropertyPointer VariablePointer() => new() { New = new FFieldPath { Path = [variableName], ResolvedOwner = coopControllerClass } };

        // Cast<CoopController_C>(GetPlayerController(self, 1)): the first CoopController, which exists for the whole map
        EX_DynamicCast CoopController() => new() {
            ClassPtr = coopControllerClass,
            Target = new EX_CallMath { StackNode = getPlayerController, Parameters = [new EX_Self(), new EX_IntConst { Value = 1 }] }
        };

        EX_Context CoopVariable() => new() {
            ObjectExpression = CoopController(),
            Offset = 9, // size of EX_InstanceVariable
            RValuePointer = VariablePointer(),
            ContextExpression = new EX_InstanceVariable { Variable = VariablePointer() }
        };

        EX_CallMath CoopControllerIsValid() => new() { StackNode = isValid, Parameters = [CoopController()] };

        // OnBattleBeginTransitionRequested sets BattleFlowState to 1 (in battle) and runs before the battle's first turn changes the user of
        // player controller 0. Only store the user when no battle is running yet, so chained battles keep the user from before the first one.
        //   if (!IsInBattle() && IsValid(CoopController)) CoopController->CoopExplorationUserId = self->GetPlatformUserId()
        {
            var func = (FunctionExport)controllerWorld["OnBattleBeginTransitionRequested"];
            KismetExpression[] store = [
                new EX_JumpIfNot {
                    BooleanExpression = new EX_CallMath { StackNode = notPreBool, Parameters = [new EX_LocalFinalFunction { StackNode = isInBattle, Parameters = [] }] }
                },
                new EX_JumpIfNot { BooleanExpression = CoopControllerIsValid() },
                new EX_Let {
                    Value = VariablePointer(),
                    Variable = CoopVariable(),
                    Expression = new EX_FinalFunction { StackNode = getPlatformUserId, Parameters = [] }
                }
            ];
            InsertStatements(controllerWorld, func, 0, store, skipTarget: true);
        }

        // ResumeExplorationOnBattleEnd: after resetting to the primary user, swap the stored user back onto player controller 0
        //   if (IsValid(CoopController)) SetPlayerPlatformUserId(PlayerController0, CoopController->CoopExplorationUserId)
        {
            var func = (FunctionExport)controllerWorld["ResumeExplorationOnBattleEnd"];
            var resetIndex = Array.FindIndex(func.ScriptBytecode, e => e is EX_CallMath call && call.StackNode.Index == setPlayerPlatformUserId.Index);
            if (resetIndex < 0)
                throw new Exception("ResumeExplorationOnBattleEnd: SetPlayerPlatformUserId call not found");
            var reset = (EX_CallMath)func.ScriptBytecode[resetIndex];
            KismetExpression[] restore = [
                new EX_JumpIfNot { BooleanExpression = CoopControllerIsValid() },
                new EX_CallMath { StackNode = setPlayerPlatformUserId, Parameters = [reset.Parameters[0], CoopVariable()] }
            ];
            InsertStatements(controllerWorld, func, resetIndex + 1, restore, skipTarget: true);
        }

        controllerWorld.SyncNamesReferencedFromExportDataCount();
    }

    // OnTurnEnded hands player controller 0 back to the primary user after every turn; outside of a battle that would undo
    // the restore from ResumeExplorationOnBattleEnd, so only reset while player controller 0 is still in battle
    public static void PatchCharacterBattleBase(UAsset characterBattleBase) {
        var gameplayStatics = characterBattleBase.FindImport("GameplayStatics", "Class");
        var getPlayerController = characterBattleBase.FindImport("GetPlayerController", outer: gameplayStatics);
        var setPlayerPlatformUserId = characterBattleBase.FindImport("SetPlayerPlatformUserId", outer: gameplayStatics);
        var controllerWorldClass = characterBattleBase.FindImport("BP_jRPG_Controller_World_C", "BlueprintGeneratedClass");

        var onTurnEnded = (FunctionExport)characterBattleBase["OnTurnEnded"];
        var onTurnStart = (FunctionExport)characterBattleBase["OnTurnStart"];
        var onTurnEndedIndex = FPackageIndex.FromExport(characterBattleBase.Exports.IndexOf(onTurnEnded));
        FProperty LocalFrom(FunctionExport func, string name) => func.LoadedProperties.First(p => p.Name.ToString() == name);
        var controllerWorld = CloneProperty(LocalFrom(onTurnStart, "K2Node_DynamicCast_AsBP_J_RPG_Controller_World"), characterBattleBase.Name("Coop_ControllerWorld"));
        var inBattle = CloneProperty(LocalFrom(onTurnStart, "K2Node_DynamicCast_bSuccess"), characterBattleBase.Name("Coop_IsInBattle"));
        if (onTurnEnded.LoadedProperties.Any(p => p.Name.ToString() is "Coop_ControllerWorld" or "Coop_IsInBattle"))
            throw new Exception("OnTurnEnded is already patched");
        onTurnEnded.LoadedProperties = [..onTurnEnded.LoadedProperties, controllerWorld, inBattle];

        KismetPropertyPointer Local(FProperty prop) => new() { New = new FFieldPath { Path = [prop.Name], ResolvedOwner = onTurnEndedIndex } };

        var resetIndex = Array.FindIndex(onTurnEnded.ScriptBytecode, e => e is EX_CallMath call && call.StackNode.Index == setPlayerPlatformUserId.Index);
        if (resetIndex < 0)
            throw new Exception("OnTurnEnded: SetPlayerPlatformUserId call not found");
        // the reset is GetPrimaryPlatformUser, GetPlayerController(self, 0), SetPlayerPlatformUserId; guard all three
        var guardIndex = resetIndex - 2;

        //   Coop_ControllerWorld = Cast<BP_jRPG_Controller_World_C>(GetPlayerController(self, 0))
        //   Coop_IsInBattle = Coop_ControllerWorld->IsInBattle()  (false if the cast failed)
        //   if (!Coop_IsInBattle) skip the reset
        KismetExpression[] guard = [
            new EX_LetObj {
                VariableExpression = new EX_LocalVariable { Variable = Local(controllerWorld) },
                AssignmentExpression = new EX_DynamicCast {
                    ClassPtr = controllerWorldClass,
                    Target = new EX_CallMath { StackNode = getPlayerController, Parameters = [new EX_Self(), new EX_IntConst { Value = 0 }] }
                }
            },
            new EX_LetBool {
                VariableExpression = new EX_LocalVariable { Variable = Local(inBattle) },
                AssignmentExpression = new EX_Context {
                    ObjectExpression = new EX_LocalVariable { Variable = Local(controllerWorld) },
                    Offset = 14, // size of EX_LocalVirtualFunction without parameters
                    RValuePointer = Local(inBattle),
                    ContextExpression = new EX_LocalVirtualFunction { VirtualFunctionName = characterBattleBase.Name("IsInBattle"), Parameters = [] }
                }
            },
            new EX_JumpIfNot { BooleanExpression = new EX_LocalVariable { Variable = Local(inBattle) } }
        ];
        InsertStatements(characterBattleBase, onTurnEnded, guardIndex, guard, skipTarget: resetIndex + 1);
        characterBattleBase.SyncNamesReferencedFromExportDataCount();
    }

    // Inserts statements before func.ScriptBytecode[index] and shifts all code offsets that point past the insertion point.
    // A jump targeting the insertion point itself lands on the inserted statements.
    // The last EX_JumpIfNot among the inserted statements without a CodeOffset is pointed at skipTarget: either the first statement after the
    // inserted ones (true) or the original statement index given.
    static void InsertStatements(UAsset asset, FunctionExport func, int index, KismetExpression[] statements, object? skipTarget = null) {
        var offsets = StatementOffsets(asset, func.ScriptBytecode);
        var insertAt = offsets[index];
        foreach (var statement in func.ScriptBytecode) {
            uint visitOffset = 0;
            statement.Visit(asset, ref visitOffset, (expression, _) => {
                if (expression is EX_SwitchValue or EX_ComputedJump)
                    throw new Exception($"{func.ObjectName}: {expression.GetType().Name} is not supported when inserting code");
            });
        }

        var size = (uint)statements.Sum(s => ExpressionSize(asset, s));
        var target = skipTarget switch {
            true => insertAt + size,
            int originalIndex => offsets[originalIndex] + size,
            _ => (uint?)null
        };
        if (target != null)
            foreach (var jump in statements.OfType<EX_JumpIfNot>())
                jump.CodeOffset = target.Value;

        foreach (var statement in func.ScriptBytecode) {
            switch (statement) {
                case EX_Jump jump when jump.CodeOffset > insertAt: jump.CodeOffset += size; break;
                case EX_JumpIfNot jump when jump.CodeOffset > insertAt: jump.CodeOffset += size; break;
                case EX_Skip skip when skip.CodeOffset > insertAt: skip.CodeOffset += size; break;
                case EX_PushExecutionFlow push when push.PushingAddress > insertAt: push.PushingAddress += size; break;
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

    // copies all public fields of an FProperty (all of its serialized state) under a new name
    static T CloneProperty<T>(T source, FName name) where T : FProperty {
        var clone = (T)Activator.CreateInstance(source.GetType())!;
        foreach (var field in source.GetType().GetFields(BindingFlags.Public | BindingFlags.Instance))
            field.SetValue(clone, field.GetValue(source));
        clone.Name = name;
        return clone;
    }
}

public static class UAssetExtensions {
    public static FName Name(this UAsset asset, string name) => new(asset, asset.AddNameReference(new FString(name)));

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

    // retoc uses this count when converting to zen; names added after loading must be included
    public static void SyncNamesReferencedFromExportDataCount(this UAsset asset) =>
        typeof(UAsset).GetField("NamesReferencedFromExportDataCount", BindingFlags.NonPublic | BindingFlags.Instance)!
            .SetValue(asset, asset.GetNameMapIndexList().Count);
}
