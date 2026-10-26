using UAssetAPI;
using UAssetAPI.ExportTypes;
using UAssetAPI.FieldTypes;
using UAssetAPI.Kismet.Bytecode;
using UAssetAPI.Kismet.Bytecode.Expressions;
using UAssetAPI.UnrealTypes;
using static BlueprintPatching;

// After a battle the exploration controller (player controller 0) used to be handed back to the primary user (player 1).
// These patches remember which user controlled the exploration character when the battle started and give control back to that user afterwards.
public static class ControlRestorePatch {
    const string VariableName = "CoopExplorationUserId";

    // adds the CoopController_C::CoopExplorationUserId variable, cloned from Tmp_UserId (FPlatformUserId)
    public static void PatchCoopController(UAsset coopController) =>
        AddVariable(coopController, "CoopController_C", "Tmp_UserId", VariableName);

    // stores the controlling user when a battle begins and restores it in ResumeExplorationOnBattleEnd
    public static void PatchControllerWorld(UAsset controllerWorld) {
        var expressions = new ControllerWorldExpressions(controllerWorld);
        var setPlayerPlatformUserId = controllerWorld.FindImport("SetPlayerPlatformUserId", outer: controllerWorld.FindImport("GameplayStatics", "Class"));
        var getPlatformUserId = controllerWorld.FindOrAddFunctionImport(controllerWorld.FindImport("PlayerController", "Class"), "GetPlatformUserId");
        var variable = PropertyPointer(controllerWorld.Name(VariableName), expressions.CoopControllerClass);
        EX_Context CoopVariable() => MemberOf(expressions.CoopController(), variable);

        // OnBattleBeginTransitionRequested sets BattleFlowState to 1 (in battle) and runs before the battle's first turn changes the user of
        // player controller 0. Only store the user when no battle is running yet, so chained battles keep the user from before the first one.
        //   if (!IsInBattle() && IsValid(CoopController)) CoopController->CoopExplorationUserId = self->GetPlatformUserId()
        {
            var func = (FunctionExport)controllerWorld["OnBattleBeginTransitionRequested"];
            KismetExpression[] store = [
                expressions.SkipIfInBattle(),
                expressions.SkipIfNoCoopController(),
                new EX_Let {
                    Value = variable,
                    Variable = CoopVariable(),
                    Expression = new EX_FinalFunction { StackNode = getPlatformUserId, Parameters = [] }
                }
            ];
            Splice(controllerWorld, func, 0, 0, store, skipTarget: true);
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
                expressions.SkipIfNoCoopController(),
                new EX_CallMath { StackNode = setPlayerPlatformUserId, Parameters = [reset.Parameters[0], CoopVariable()] }
            ];
            Splice(controllerWorld, func, resetIndex + 1, 0, restore, skipTarget: true);
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
        var onTurnEndedIndex = characterBattleBase.ExportIndex("OnTurnEnded");
        if (onTurnEnded.LoadedProperties.Any(p => p.Name.ToString() is "Coop_ControllerWorld" or "Coop_IsInBattle"))
            throw new Exception("OnTurnEnded is already patched");
        FProperty LocalFrom(FunctionExport func, string name) => func.LoadedProperties.First(p => p.Name.ToString() == name);
        var controllerWorld = CloneProperty(LocalFrom(onTurnStart, "K2Node_DynamicCast_AsBP_J_RPG_Controller_World"), characterBattleBase.Name("Coop_ControllerWorld"));
        var inBattle = CloneProperty(LocalFrom(onTurnStart, "K2Node_DynamicCast_bSuccess"), characterBattleBase.Name("Coop_IsInBattle"));
        onTurnEnded.LoadedProperties = [..onTurnEnded.LoadedProperties, controllerWorld, inBattle];

        KismetPropertyPointer Local(FProperty prop) => PropertyPointer(prop.Name, onTurnEndedIndex);

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
        Splice(characterBattleBase, onTurnEnded, guardIndex, 0, guard, skipTarget: resetIndex + 1);
        characterBattleBase.SyncNamesReferencedFromExportDataCount();
    }
}
