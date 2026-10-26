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

    // Bit 8 of the roll marks "keep the roll for the next battle". It is set when a battle is lost, because "Retry" ends the battle as
    // lost and immediately requests it again, and the retried battle should keep the assignments of the lost one.
    const int KeepRoll = 8;
    const byte BattleLost = 2; // EBattleEndResult, set by AC_jRPG_BattleManager when all heroes are killed

    // OnBattleBeginTransitionRequested (battle begins):
    //   if (!IsInBattle() && IsValid(CoopController) && IsValid(Config))
    //     Config->RandomAssignmentRoll = Roll >= 8 ? Roll - 8 : RandomIntegerInRange(0, 7)
    // ResumeExplorationOnBattleEnd (battle ends):
    //   if (BattleEndResult == Lost && IsValid(CoopController) && IsValid(Config)) Config->RandomAssignmentRoll = Roll % 8 + 8
    // Config is CoopController->ModActor->CoopConfig, the config ModLibrary::LoadCoopConfig returns for every assignment lookup
    public static void PatchControllerWorld(UAsset controllerWorld) {
        var expressions = new ControllerWorldExpressions(controllerWorld);
        var kismetMathLibrary = controllerWorld.FindImport("KismetMathLibrary", "Class");
        FPackageIndex Math(string name) => controllerWorld.FindOrAddFunctionImport(kismetMathLibrary, name);
        EX_CallMath Call(string function, params KismetExpression[] parameters) => new() { StackNode = Math(function), Parameters = parameters };
        EX_IntConst Int(int value) => new() { Value = value };

        var roll = PropertyPointer(controllerWorld.Name(RollName), expressions.CoopConfigClass);
        EX_Context Roll() => MemberOf(expressions.CoopConfig(), roll);
        KismetExpression[] Guarded(KismetExpression condition, KismetExpression assignment) => [
            new EX_JumpIfNot { BooleanExpression = condition },
            expressions.SkipIfNoCoopController(),
            new EX_JumpIfNot { BooleanExpression = expressions.IsValid(expressions.CoopConfig()) },
            new EX_Let { Value = roll, Variable = Roll(), Expression = assignment }
        ];

        {
            var func = (FunctionExport)controllerWorld["OnBattleBeginTransitionRequested"];
            var notInBattle = expressions.SkipIfInBattle().BooleanExpression;
            var next = Call("SelectInt",
                Call("Subtract_IntInt", Roll(), Int(KeepRoll)),
                Call("RandomIntegerInRange", Int(0), Int(KeepRoll - 1)),
                Call("GreaterEqual_IntInt", Roll(), Int(KeepRoll)));
            Splice(controllerWorld, func, 0, 0, Guarded(notInBattle, next), skipTarget: true);
        }

        {
            var func = (FunctionExport)controllerWorld["ResumeExplorationOnBattleEnd"];
            var battleEndResult = PropertyPointer(controllerWorld.Name("BattleEndResult"), controllerWorld.ExportIndex("ResumeExplorationOnBattleEnd"));
            var lost = Call("EqualEqual_ByteByte", new EX_LocalVariable { Variable = battleEndResult }, new EX_ByteConst { Value = BattleLost });
            var keep = Call("Add_IntInt", Call("Percent_IntInt", Roll(), Int(KeepRoll)), Int(KeepRoll));
            Splice(controllerWorld, func, 0, 0, Guarded(lost, keep), skipTarget: true);
        }

        controllerWorld.SyncNamesReferencedFromExportDataCount();
    }
}
