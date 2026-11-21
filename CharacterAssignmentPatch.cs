using UAssetAPI;
using UAssetAPI.ExportTypes;
using UAssetAPI.FieldTypes;
using UAssetAPI.Kismet.Bytecode;
using UAssetAPI.Kismet.Bytecode.Expressions;
using UAssetAPI.UnrealTypes;
using static BlueprintPatching;

// The character assignment settings (Character<N>Assignment) belong to party slots, so when the party changes (e.g. Verso replacing
// Gustave) players end up with other characters. Make them follow the characters: CoopConfig_C gets <Name>Assignment per playable
// character, holding the assignment + 1 (0 = never assigned, so configs saved before this patch keep working).
// - WBP_Settings_GeneralOptionsList::UpdateChar<N>Assignment: after the slot changes, remember the assignment of every party member
// - ModLibrary::LoadCoopConfig and SetupSettingsMenu: before the slots are read, copy the remembered assignments to the slots the
//   characters are in now. Once any character is remembered, characters that never were get player 1; before that the slots apply.
// - SetupSettingsMenu names the character in each slot ("Character 1 Assignment (Sciel)")
// - PlayerIndicator (the P<N> badge on the team screen) shows the character's player instead of its party slot, "P?" for random
public static class CharacterAssignmentPatch {
    // CharacterHardcodedName of the playable characters and the names shown for them (Frey is Gustave)
    static readonly (string Name, string Display)[] Characters =
        [("Frey", "Gustave"), ("Lune", "Lune"), ("Maelle", "Maelle"), ("Sciel", "Sciel"), ("Monoco", "Monoco"), ("Verso", "Verso")];
    const int Slots = 3;
    const int RandomValue = 3; // RandomAssignmentPatch's "Random (P1/P2)"
    const string GetPartyIndexByName = "Get Party Index By Name";
    const string PartyIndexLocal = "Coop_PartyIndex";
    const string InPartyLocal = "Coop_InParty";

    static string SlotVariable(int slot) => $"Character{slot + 1}Assignment";
    static string CharacterVariable(string character) => $"{character}Assignment";
    static string LabelLocal(int slot) => $"Coop_Label{slot + 1}";

    static EX_TextConst Text(string text) => new() {
        Value = new FScriptText { TextLiteralType = EBlueprintTextLiteralType.InvariantText, InvariantLiteralString = new EX_StringConst { Value = text } }
    };

    public static void PatchCoopConfig(UAsset coopConfig) {
        foreach (var (character, _) in Characters)
            AddVariable(coopConfig, "CoopConfig_C", SlotVariable(0), CharacterVariable(character));
        coopConfig.SyncNamesReferencedFromExportDataCount();
    }

    // LoadCoopConfig(__WorldContext) -> Coop Config: apply the remembered assignments before returning
    // SetupSettingsMenu: apply them to the config loaded from the save slot before the selectors are created from it
    public static void PatchModLibrary(UAsset modLibrary) {
        var templates = (FunctionExport)modLibrary["Is Overriden Solo Battle"];
        var b = new Builder(modLibrary, modLibrary.FindImport("CoopConfig_C", "BlueprintGeneratedClass"));
        KismetExpression WorldContext() => new EX_LocalVariable { Variable = PropertyPointer(modLibrary.Name("__WorldContext"), b.Function) };
        KismetExpression GetPartyIndex(string character) => new EX_LocalVirtualFunction {
            VirtualFunctionName = modLibrary.Name(GetPartyIndexByName),
            Parameters = [new EX_NameConst { Value = modLibrary.Name(character) }, WorldContext(), b.Local(PartyIndexLocal), b.Local(InPartyLocal)]
        };

        {
            var func = (FunctionExport)modLibrary["LoadCoopConfig"];
            b.Use(func, modLibrary.ExportIndex("LoadCoopConfig"), templates);
            var index = Array.FindIndex(func.ScriptBytecode, e => e is EX_Return);
            if (index < 0)
                throw new Exception("LoadCoopConfig: return not found");
            var config = PropertyPointer(modLibrary.Name("Coop Config"), b.Function);
            b.ApplyRemembered(func, index, () => new EX_LocalOutVariable { Variable = config }, GetPartyIndex);
        }

        {
            var func = (FunctionExport)modLibrary["SetupSettingsMenu"];
            b.Use(func, modLibrary.ExportIndex("SetupSettingsMenu"), templates);
            var config = PropertyPointer(modLibrary.Name("Config"), b.Function);
            // Config = cast<CoopConfig_C>(LoadGameFromSlot("Coop", 0)), the selectors are created right after it
            var index = Array.FindIndex(func.ScriptBytecode, e =>
                e is EX_LetObj { VariableExpression: EX_LocalVariable variable, AssignmentExpression: EX_LocalVariable } &&
                variable.Variable.New.Path[0].ToString() == "Config");
            if (index < 0)
                throw new Exception("SetupSettingsMenu: assignment of the loaded config not found");
            b.ApplyRemembered(func, index + 1, () => new EX_LocalVariable { Variable = config }, GetPartyIndex);
            NameAndDescribeSlots(modLibrary, func, b, GetPartyIndex);
        }

        modLibrary.SyncNamesReferencedFromExportDataCount();
    }

    const string DescriptionPrefix = "Select which player should control character ";
    const string RememberedNote = " The choice is remembered for the character in this party position, and follows them when the party order changes.";

    // CreateOptionsEntry(ScrollBox, Selector, "Character <N> Assignment", "Select which player should control character <N>...", ...):
    //   the name gets the character now in slot N, the description says that the choice sticks to the character
    static void NameAndDescribeSlots(UAsset modLibrary, FunctionExport setupSettingsMenu, Builder b, Func<string, KismetExpression> getPartyIndex) {
        int[] Entries() {
            var found = new int[Slots];
            Array.Fill(found, -1);
            for (var i = 0; i < setupSettingsMenu.ScriptBytecode.Length; i++) {
                if (setupSettingsMenu.ScriptBytecode[i] is not EX_LetObj { AssignmentExpression: EX_LocalVirtualFunction { Parameters: [_, _, _, EX_TextConst description, ..] } })
                    continue;
                var source = (description.Value.LocalizedSource ?? description.Value.InvariantLiteralString) as EX_StringConst;
                if (source?.Value.StartsWith(DescriptionPrefix) != true)
                    continue;
                var slot = source.Value[DescriptionPrefix.Length] - '1';
                if (slot is < 0 or >= Slots || found[slot] >= 0)
                    throw new Exception($"SetupSettingsMenu: unexpected character assignment description \"{source.Value}\"");
                found[slot] = i;
            }
            if (found.Any(i => i < 0))
                throw new Exception("SetupSettingsMenu: character assignment options not found");
            return found;
        }

        var entries = Entries();
        var names = new KismetExpression[Slots];
        for (var slot = 0; slot < Slots; slot++) {
            var create = (EX_LocalVirtualFunction)((EX_LetObj)setupSettingsMenu.ScriptBytecode[entries[slot]]).AssignmentExpression;
            names[slot] = create.Parameters[2];
        }
        var optionName = ((FunctionExport)modLibrary["CreateOptionsEntry"]).LoadedProperties.First(p => p.Name.ToString() == "OptionName");
        foreach (var slot in Enumerable.Range(0, Slots)) {
            var label = CloneProperty(optionName, modLibrary.Name(LabelLocal(slot)));
            label.PropertyFlags = EPropertyFlags.CPF_None;
            setupSettingsMenu.LoadedProperties = [..setupSettingsMenu.LoadedProperties, label];
        }
        var baseNames = names.Select(name => (((EX_TextConst)name).Value.LocalizedSource ?? ((EX_TextConst)name).Value.InvariantLiteralString) is EX_StringConst s
            ? s.Value : throw new Exception("SetupSettingsMenu: option name is not a literal")).ToArray();

        // Label<N> = "Character <N> Assignment"; for each character in slot N: Label<N> = "Character <N> Assignment (<character>)"
        KismetExpression[] labels = [
            ..Enumerable.Range(0, Slots).Select(slot => b.SetLocal(LabelLocal(slot), names[slot])),
            ..Characters.SelectMany(character => (KismetExpression[])[
                getPartyIndex(character.Name),
                ..Enumerable.Range(0, Slots).Select(slot => b.SetLocal(LabelLocal(slot),
                    b.Math("SelectText", Text($"{baseNames[slot]} ({character.Display})"), b.Local(LabelLocal(slot)),
                        b.Math("BooleanAND", b.Local(InPartyLocal), b.PartyIndexIs(slot)))))
            ])
        ];
        Splice(modLibrary, setupSettingsMenu, entries.Min(), 0, labels);

        entries = Entries();
        for (var slot = 0; slot < Slots; slot++) {
            var let = (EX_LetObj)setupSettingsMenu.ScriptBytecode[entries[slot]];
            var create = (EX_LocalVirtualFunction)let.AssignmentExpression;
            var description = (EX_TextConst)create.Parameters[3];
            var source = (EX_StringConst)(description.Value.LocalizedSource ?? description.Value.InvariantLiteralString);
            KismetExpression replaced = new EX_LetObj {
                VariableExpression = let.VariableExpression,
                AssignmentExpression = new EX_LocalVirtualFunction {
                    VirtualFunctionName = create.VirtualFunctionName,
                    Parameters = [..create.Parameters[..2], b.Local(LabelLocal(slot)), Text(source.Value + RememberedNote), ..create.Parameters[4..]]
                }
            };
            Splice(modLibrary, setupSettingsMenu, entries[slot], 1, [replaced]);
        }
    }

    // UpdateChar<N>Assignment(Value): Config->Character<N>Assignment = Value; remember the slots' assignments; SaveGameToSlot(Config)
    public static void PatchSettingsList(UAsset settingsList) {
        var modLibraryDefaults = settingsList.FindImport("Default__ModLibrary_C");
        var b = new Builder(settingsList, settingsList.FindImport("CoopConfig_C", "BlueprintGeneratedClass"));
        for (var slot = 0; slot < Slots; slot++) {
            var name = $"UpdateChar{slot + 1}Assignment";
            var func = (FunctionExport)settingsList[name];
            b.Use(func, settingsList.ExportIndex(name), func);
            var config = PropertyPointer(settingsList.Name("CallFunc_LoadCoopConfig_Coop_Config"), b.Function);
            var index = Array.FindIndex(func.ScriptBytecode, e => e is EX_LetBool { AssignmentExpression: EX_CallMath call } &&
                call.Parameters.Length == 3 && call.Parameters[1] is EX_StringConst { Value: "Coop" });
            if (index < 0)
                throw new Exception($"{name}: SaveGameToSlot not found");
            KismetExpression GetPartyIndex(string character) => CallOn(settingsList, new EX_ObjectConst { Value = modLibraryDefaults },
                new EX_LocalVirtualFunction {
                    VirtualFunctionName = settingsList.Name(GetPartyIndexByName),
                    Parameters = [new EX_NameConst { Value = settingsList.Name(character) }, new EX_Self(), b.Local(PartyIndexLocal), b.Local(InPartyLocal)]
                });
            b.Remember(func, index, () => new EX_LocalVariable { Variable = config }, GetPartyIndex);
        }
        settingsList.SyncNamesReferencedFromExportDataCount();
    }

    // GetText formats "P{T}" with T = the character's party slot + 1. Right after T is stored in the format argument, when a coop config exists:
    //   T = player + 1, or the text "?" when the assignment is random. player is resolved like ApplyRemembered: the remembered assignment,
    //   else player 1 once any character is remembered, else the slot's assignment (guests always use their slot)
    public static void PatchPlayerIndicator(UAsset playerIndicator) {
        var func = (FunctionExport)playerIndicator["GetText"];
        var funcIndex = playerIndicator.ExportIndex("GetText");
        var gameplayStatics = playerIndicator.TryFindImport("GameplayStatics", "Class") ?? Builder.AddScriptClass(playerIndicator, "GameplayStatics");
        var coopControllerClass = playerIndicator.FindOrAddBlueprintClassImport("/Game/Coop/CoopController", "CoopController_C");
        var modActorClass = playerIndicator.FindOrAddBlueprintClassImport("/Game/Coop/ModActor", "ModActor_C");
        var b = new Builder(playerIndicator, playerIndicator.FindOrAddBlueprintClassImport("/Game/Coop/CoopConfig", "CoopConfig_C"));
        b.SetFunction(funcIndex);

        KismetExpression CoopController() => new EX_DynamicCast {
            ClassPtr = coopControllerClass,
            Target = new EX_CallMath {
                StackNode = playerIndicator.FindOrAddFunctionImport(gameplayStatics, "GetPlayerController"),
                Parameters = [new EX_Self(), new EX_IntConst { Value = 1 }]
            }
        };
        KismetExpression Config() => MemberOf(MemberOf(CoopController(), PropertyPointer(playerIndicator.Name("ModActor"), coopControllerClass)),
            PropertyPointer(playerIndicator.Name("CoopConfig"), modActorClass));
        KismetExpression CharacterName() => new EX_InstanceVariable {
            Variable = PropertyPointer(playerIndicator.Name("CharacterName"), playerIndicator.ExportIndex("PlayerIndicator_C"))
        };
        // GetText is a binding evaluated every frame: resolve the player once into a local
        const string PlayerLocal = "Coop_Player";
        var intTemplate = func.LoadedProperties.First(p => p.SerializedType?.ToString() == "IntProperty" && !p.PropertyFlags.HasFlag(EPropertyFlags.CPF_Parm));
        var player = CloneProperty(intTemplate, playerIndicator.Name(PlayerLocal));
        player.PropertyFlags = EPropertyFlags.CPF_None;
        func.LoadedProperties = [..func.LoadedProperties, player];
        KismetExpression Player() => b.Local(PlayerLocal);

        EX_Let Argument(string member) => func.ScriptBytecode.OfType<EX_Let>().SingleOrDefault(let =>
            let.Variable is EX_StructMemberContext { StructMemberExpression: var pointer } && pointer.New.Path[0].ToString() == member)
            ?? throw new Exception($"PlayerIndicator.GetText: assignment of the format argument's {member} not found");
        var valueInt = Argument("ArgumentValueInt");
        var valueType = Argument("ArgumentValueType");
        var value = Argument("ArgumentValue");
        KismetExpression IsRandom() => b.Math("EqualEqual_IntInt", Player(), new EX_IntConst { Value = RandomValue });

        KismetExpression[] showPlayer = [
            new EX_JumpIfNot { BooleanExpression = b.IsValid(CoopController()) },
            new EX_JumpIfNot { BooleanExpression = b.IsValid(Config()) },
            b.SetLocal(PlayerLocal, b.EffectivePlayer(Config, CharacterName, () => b.Local("CallFunc_Get_Party_Index_By_Name_Index"))),
            new EX_Let { Value = valueInt.Value, Variable = valueInt.Variable, Expression = b.Math("Conv_IntToInt64", b.Math("Add_IntInt", Player(), new EX_IntConst { Value = 1 })) },
            new EX_Let { Value = valueType.Value, Variable = valueType.Variable, Expression = b.Math("Conv_IntToByte",
                b.Math("SelectInt", new EX_IntConst { Value = 4 /* EFormatArgumentType::Text */ }, new EX_IntConst { Value = 0 /* Int */ }, IsRandom())) },
            new EX_Let { Value = value.Value, Variable = value.Variable, Expression = b.Math("SelectText", Text("?"), value.Variable, IsRandom()) }
        ];
        Splice(playerIndicator, func, Array.IndexOf(func.ScriptBytecode, valueInt) + 1, 0, showPlayer, skipTarget: true);
        playerIndicator.SyncNamesReferencedFromExportDataCount();
    }

    sealed class Builder(UAsset asset, FPackageIndex coopConfigClass) {
        readonly FPackageIndex math = asset.TryFindImport("KismetMathLibrary", "Class") ?? AddScriptClass(asset, "KismetMathLibrary");
        readonly FPackageIndex system = asset.TryFindImport("KismetSystemLibrary", "Class") ?? AddScriptClass(asset, "KismetSystemLibrary");
        public FPackageIndex Function { get; private set; } = FPackageIndex.FromRawIndex(0);

        public static FPackageIndex AddScriptClass(UAsset asset, string name) =>
            asset.FindOrAddImport("/Script/CoreUObject", "Class", asset.FindOrAddImport("/Script/CoreUObject", "Package", FPackageIndex.FromRawIndex(0), "/Script/Engine"), name);

        public void SetFunction(FPackageIndex funcIndex) => Function = funcIndex;

        // adds the int and bool locals receiving GetPartyIndexByName's outputs to func, cloned from local variables of template
        public void Use(FunctionExport func, FPackageIndex funcIndex, FunctionExport template) {
            Function = funcIndex;
            if (func.LoadedProperties.Any(p => p.Name.ToString() is PartyIndexLocal or InPartyLocal))
                throw new Exception($"{func.ObjectName} is already patched");
            // int locals are only found as parameters in some functions, a clone of one is a plain local without the parameter flags
            var ints = template.LoadedProperties.Where(p => p.SerializedType?.ToString() == "IntProperty").ToList();
            var intTemplate = ints.FirstOrDefault(p => !p.PropertyFlags.HasFlag(EPropertyFlags.CPF_Parm)) ?? ints.FirstOrDefault()
                              ?? throw new Exception($"{template.ObjectName} has no int variable to clone");
            var boolTemplate = template.LoadedProperties.FirstOrDefault(p => p is FBoolProperty && !p.PropertyFlags.HasFlag(EPropertyFlags.CPF_Parm))
                               ?? throw new Exception($"{template.ObjectName} has no bool local to clone");
            var partyIndex = CloneProperty(intTemplate, asset.Name(PartyIndexLocal));
            partyIndex.PropertyFlags = EPropertyFlags.CPF_None;
            var inParty = CloneProperty(boolTemplate, asset.Name(InPartyLocal));
            inParty.PropertyFlags = EPropertyFlags.CPF_None;
            func.LoadedProperties = [..func.LoadedProperties, partyIndex, inParty];
        }

        public EX_LocalVariable Local(string name) => new() { Variable = PropertyPointer(asset.Name(name), Function) };
        public EX_Let SetLocal(string name, KismetExpression value) =>
            new() { Value = PropertyPointer(asset.Name(name), Function), Variable = Local(name), Expression = value };
        EX_CallMath Call(FPackageIndex library, string function, params KismetExpression[] parameters) =>
            new() { StackNode = asset.FindOrAddFunctionImport(library, function), Parameters = parameters };
        public EX_CallMath Math(string function, params KismetExpression[] parameters) => Call(math, function, parameters);
        public EX_CallMath IsValid(KismetExpression obj) => Call(system, "IsValid", obj);
        static EX_IntConst Int(int value) => new() { Value = value };
        KismetPropertyPointer Variable(string name) => PropertyPointer(asset.Name(name), coopConfigClass);
        EX_Context Member(Func<KismetExpression> config, string name) => MemberOf(config(), Variable(name));
        EX_Let Set(Func<KismetExpression> config, string name, KismetExpression value) =>
            new() { Value = Variable(name), Variable = Member(config, name), Expression = value };
        EX_JumpIfNot SkipIfNoConfig(Func<KismetExpression> config) => new() { BooleanExpression = IsValid(config()) };
        public EX_CallMath PartyIndexIs(int slot) => Math("EqualEqual_IntInt", Local(PartyIndexLocal), Int(slot));

        KismetExpression Or(IEnumerable<KismetExpression> conditions) => conditions.Aggregate((a, c) => Math("BooleanOR", a, c));

        // any <Character>Assignment > 0: the players use per-character assignments
        KismetExpression AnyRemembered(Func<KismetExpression> config) =>
            Or(Characters.Select(c => Math("Greater_IntInt", Member(config, CharacterVariable(c.Name)), Int(0))));

        // <Character>Assignment > 0 ? <Character>Assignment - 1 : player 1
        KismetExpression RememberedOrPlayer1(Func<KismetExpression> remembered) =>
            Math("SelectInt", Math("Subtract_IntInt", remembered(), Int(1)), Int(0), Math("Greater_IntInt", remembered(), Int(0)));

        // the player of the character called name in party slot partyIndex, as ApplyRemembered resolves it
        public KismetExpression EffectivePlayer(Func<KismetExpression> config, Func<KismetExpression> name, Func<KismetExpression> partyIndex) {
            KismetExpression NameIs(string character) => Math("EqualEqual_NameName", name(), new EX_NameConst { Value = asset.Name(character) });
            KismetExpression Remembered() => Characters.Aggregate((KismetExpression)Int(0),
                (other, c) => Math("SelectInt", Member(config, CharacterVariable(c.Name)), other, NameIs(c.Name)));
            KismetExpression SlotPlayer() => Math("SelectInt", Member(config, SlotVariable(0)),
                Math("SelectInt", Member(config, SlotVariable(1)), Member(config, SlotVariable(2)), Math("EqualEqual_IntInt", partyIndex(), Int(1))),
                Math("EqualEqual_IntInt", partyIndex(), Int(0)));
            var known = Or(Characters.Select(c => NameIs(c.Name)));
            return Math("SelectInt", RememberedOrPlayer1(Remembered), SlotPlayer(),
                Math("BooleanAND", known, AnyRemembered(config)));
        }

        // for each character:
        //   if (IsValid(Config)) { GetPartyIndexByName(Character, out PartyIndex, out InParty)
        //     if (InParty && any character is remembered)
        //       Config->Character<N>Assignment = PartyIndex == N - 1 ? (remembered ? <Character>Assignment - 1 : player 1) : Config->Character<N>Assignment }
        public void ApplyRemembered(FunctionExport func, int index, Func<KismetExpression> config, Func<string, KismetExpression> getPartyIndex) {
            foreach (var (character, _) in Characters) {
                var remembered = CharacterVariable(character);
                KismetExpression[] block = [
                    SkipIfNoConfig(config),
                    getPartyIndex(character),
                    new EX_JumpIfNot { BooleanExpression = Math("BooleanAND", Local(InPartyLocal), AnyRemembered(config)) },
                    ..Enumerable.Range(0, Slots).Select(slot => Set(config, SlotVariable(slot),
                        Math("SelectInt", RememberedOrPlayer1(() => Member(config, remembered)),
                            Member(config, SlotVariable(slot)), PartyIndexIs(slot))))
                ];
                Splice(asset, func, index, 0, block, skipTarget: true);
                index += block.Length;
            }
        }

        // for each character:
        //   if (IsValid(Config)) { GetPartyIndexByName(Character, out PartyIndex, out InParty)
        //     if (InParty && PartyIndex < 3) Config-><Character>Assignment = Config->Character<PartyIndex + 1>Assignment + 1 }
        public void Remember(FunctionExport func, int index, Func<KismetExpression> config, Func<string, KismetExpression> getPartyIndex) {
            foreach (var (character, _) in Characters) {
                var slotAssignment = Math("SelectInt", Member(config, SlotVariable(0)),
                    Math("SelectInt", Member(config, SlotVariable(1)), Member(config, SlotVariable(2)), PartyIndexIs(1)), PartyIndexIs(0));
                KismetExpression[] block = [
                    SkipIfNoConfig(config),
                    getPartyIndex(character),
                    new EX_JumpIfNot { BooleanExpression = Math("BooleanAND", Local(InPartyLocal), Math("Less_IntInt", Local(PartyIndexLocal), Int(Slots))) },
                    Set(config, CharacterVariable(character), Math("Add_IntInt", slotAssignment, Int(1)))
                ];
                Splice(asset, func, index, 0, block, skipTarget: true);
                index += block.Length;
            }
        }
    }
}
