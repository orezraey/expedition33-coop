using UAssetAPI;
using UAssetAPI.ExportTypes;
using UAssetAPI.Kismet.Bytecode;
using UAssetAPI.Kismet.Bytecode.Expressions;
using UAssetAPI.UnrealTypes;
using static BlueprintPatching;

// Adds a "Random (P1/P2)" choice to the character assignment settings. The setting is stored as Character<N>Assignment = 3 and resolved
// whenever the assignment is read, from CoopConfig_C::RandomAssignmentRoll (3 random bits, one per character) which is rolled when a battle begins.
// The roll is transient: it isn't written to the "Coop" save slot, so the setting itself stays "Random".
public static class RandomAssignmentPatch {
    const int RandomValue = 3;
    const string RandomLabel = "Random (P1/P2)";
    const string RollName = "RandomAssignmentRoll";

    // CreateIntegerSelector builds the {0: Player 1, 1: Player 2, 2: Player 3} map shown by every character assignment option
    public static void PatchModLibrary(UAsset modLibrary) {
        var func = (FunctionExport)modLibrary["CreateIntegerSelector"];
        var index = Array.FindIndex(func.ScriptBytecode, e => e is EX_SetMap);
        if (index < 0)
            throw new Exception("CreateIntegerSelector: player map not found");
        var map = (EX_SetMap)func.ScriptBytecode[index];
        if (map.Elements.OfType<EX_IntConst>().Any(e => e.Value == RandomValue))
            throw new Exception("CreateIntegerSelector already has a random choice");
        KismetExpression label = new EX_TextConst {
            Value = new FScriptText {
                TextLiteralType = EBlueprintTextLiteralType.InvariantText,
                InvariantLiteralString = new EX_StringConst { Value = RandomLabel }
            }
        };
        var withRandom = new EX_SetMap { MapProperty = map.MapProperty, Elements = [..map.Elements, new EX_IntConst { Value = RandomValue }, label] };
        Splice(modLibrary, func, index, 1, [withRandom]);
        modLibrary.SyncNamesReferencedFromExportDataCount();
    }

    public static void PatchCoopConfig(UAsset coopConfig) {
        AddVariable(coopConfig, "CoopConfig_C", "Character1Assignment", RollName, EPropertyFlags.CPF_Transient);

        var kismetMathLibrary = coopConfig.FindImport("KismetMathLibrary", "Class");
        var equalEqualIntInt = coopConfig.FindOrAddFunctionImport(kismetMathLibrary, "EqualEqual_IntInt");
        var selectInt = coopConfig.FindOrAddFunctionImport(kismetMathLibrary, "SelectInt");
        var divideIntInt = coopConfig.FindOrAddFunctionImport(kismetMathLibrary, "Divide_IntInt");
        var percentIntInt = coopConfig.FindOrAddFunctionImport(kismetMathLibrary, "Percent_IntInt");
        var coopConfigClass = coopConfig.ExportIndex("CoopConfig_C");
        var roll = PropertyPointer(coopConfig.Name(RollName), coopConfigClass);

        EX_IntConst Int(int value) => new() { Value = value };
        EX_CallMath Call(FPackageIndex function, params KismetExpression[] parameters) => new() { StackNode = function, Parameters = parameters };

        // value == 3 ? (RandomAssignmentRoll / bit) % 2 : value, where bit selects the character's random bit (1, 2 or 4)
        KismetExpression Resolve(Func<KismetExpression> value, KismetExpression bit) =>
            Call(selectInt,
                Call(percentIntInt, Call(divideIntInt, new EX_InstanceVariable { Variable = roll }, bit), Int(2)),
                value(),
                Call(equalEqualIntInt, value(), Int(RandomValue)));

        // GetCharAssignment(Character) -> Player: resolve the result after the switch over Character<N>Assignment
        {
            var func = (FunctionExport)coopConfig["GetCharAssignment"];
            var funcIndex = coopConfig.ExportIndex("GetCharAssignment");
            var player = PropertyPointer(coopConfig.Name("Player"), funcIndex);
            var character = PropertyPointer(coopConfig.Name("Character"), funcIndex);
            var index = Array.FindIndex(func.ScriptBytecode, e => e is EX_Let { Variable: EX_LocalOutVariable } let && let.Value.New.Path[0].ToString() == "Player");
            if (index < 0)
                throw new Exception("GetCharAssignment: assignment of Player not found");
            KismetExpression CharacterIs(int value) => Call(equalEqualIntInt, new EX_LocalVariable { Variable = character }, Int(value));
            var bit = Call(selectInt, Int(4), Call(selectInt, Int(2), Int(1), CharacterIs(1)), CharacterIs(2));
            KismetExpression resolve = new EX_Let {
                Value = player,
                Variable = new EX_LocalOutVariable { Variable = player },
                Expression = Resolve(() => new EX_LocalOutVariable { Variable = player }, bit)
            };
            Splice(coopConfig, func, index + 1, 0, [resolve]);
        }

        // GetPlayerAssignments(Player) -> Chars: compare Player with the resolved Character<N>Assignment
        {
            var func = (FunctionExport)coopConfig["GetPlayerAssignments"];
            for (var character = 0; character < 3; character++) {
                var variableName = $"Character{character + 1}Assignment";
                var index = Array.FindIndex(func.ScriptBytecode, e =>
                    e is EX_LetBool { AssignmentExpression: EX_CallMath call } && call.StackNode.Index == equalEqualIntInt.Index &&
                    call.Parameters[1] is EX_InstanceVariable variable && variable.Variable.New.Path[0].ToString() == variableName);
                if (index < 0)
                    throw new Exception($"GetPlayerAssignments: comparison with {variableName} not found");
                var compare = (EX_LetBool)func.ScriptBytecode[index];
                var call = (EX_CallMath)compare.AssignmentExpression;
                var assignment = ((EX_InstanceVariable)call.Parameters[1]).Variable;
                KismetExpression resolved = new EX_LetBool {
                    VariableExpression = compare.VariableExpression,
                    AssignmentExpression = Call(equalEqualIntInt, call.Parameters[0], Resolve(() => new EX_InstanceVariable { Variable = assignment }, Int(1 << character)))
                };
                Splice(coopConfig, func, index, 1, [resolved]);
            }
        }

        coopConfig.SyncNamesReferencedFromExportDataCount();
    }

    // OnBattleBeginTransitionRequested: if (!IsInBattle() && IsValid(CoopController))
    //   CoopController->ModActor->CoopConfig->RandomAssignmentRoll = RandomIntegerInRange(0, 7)
    // CoopController->ModActor->CoopConfig is the config ModLibrary::LoadCoopConfig returns for every assignment lookup
    public static void PatchControllerWorld(UAsset controllerWorld) {
        var gameplayStatics = controllerWorld.FindImport("GameplayStatics", "Class");
        var kismetMathLibrary = controllerWorld.FindImport("KismetMathLibrary", "Class");
        var kismetSystemLibrary = controllerWorld.FindImport("KismetSystemLibrary", "Class");
        var getPlayerController = controllerWorld.FindImport("GetPlayerController", outer: gameplayStatics);
        var notPreBool = controllerWorld.FindImport("Not_PreBool", outer: kismetMathLibrary);
        var isValid = controllerWorld.FindImport("IsValid", outer: kismetSystemLibrary);
        var randomIntegerInRange = controllerWorld.FindOrAddFunctionImport(kismetMathLibrary, "RandomIntegerInRange");
        var coopControllerClass = controllerWorld.FindOrAddBlueprintClassImport("/Game/Coop/CoopController", "CoopController_C");
        var modActorClass = controllerWorld.FindOrAddBlueprintClassImport("/Game/Coop/ModActor", "ModActor_C");
        var coopConfigClass = controllerWorld.FindOrAddBlueprintClassImport("/Game/Coop/CoopConfig", "CoopConfig_C");
        var isInBattle = controllerWorld.ExportIndex("IsInBattle");

        EX_DynamicCast CoopController() => new() {
            ClassPtr = coopControllerClass,
            Target = new EX_CallMath { StackNode = getPlayerController, Parameters = [new EX_Self(), new EX_IntConst { Value = 1 }] }
        };
        var roll = PropertyPointer(controllerWorld.Name(RollName), coopConfigClass);
        var config = MemberOf(
            MemberOf(CoopController(), PropertyPointer(controllerWorld.Name("ModActor"), coopControllerClass)),
            PropertyPointer(controllerWorld.Name("CoopConfig"), modActorClass));

        var func = (FunctionExport)controllerWorld["OnBattleBeginTransitionRequested"];
        KismetExpression[] rollStatements = [
            new EX_JumpIfNot {
                BooleanExpression = new EX_CallMath { StackNode = notPreBool, Parameters = [new EX_LocalFinalFunction { StackNode = isInBattle, Parameters = [] }] }
            },
            new EX_JumpIfNot { BooleanExpression = new EX_CallMath { StackNode = isValid, Parameters = [CoopController()] } },
            new EX_Let {
                Value = roll,
                Variable = MemberOf(config, roll),
                Expression = new EX_CallMath { StackNode = randomIntegerInRange, Parameters = [new EX_IntConst { Value = 0 }, new EX_IntConst { Value = 7 }] }
            }
        ];
        Splice(controllerWorld, func, 0, 0, rollStatements, skipTarget: true);
        controllerWorld.SyncNamesReferencedFromExportDataCount();
    }
}
