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
//   characters are in now. Characters that were never assigned keep the assignment of their slot.
public static class CharacterAssignmentPatch {
    // CharacterHardcodedName of the playable characters (Frey is Gustave)
    static readonly string[] Characters = ["Frey", "Lune", "Maelle", "Sciel", "Monoco", "Verso"];
    const int Slots = 3;
    const string GetPartyIndexByName = "Get Party Index By Name";
    const string PartyIndexLocal = "Coop_PartyIndex";
    const string InPartyLocal = "Coop_InParty";

    static string SlotVariable(int slot) => $"Character{slot + 1}Assignment";
    static string CharacterVariable(string character) => $"{character}Assignment";

    public static void PatchCoopConfig(UAsset coopConfig) {
        foreach (var character in Characters)
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
        }

        modLibrary.SyncNamesReferencedFromExportDataCount();
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

    sealed class Builder(UAsset asset, FPackageIndex coopConfigClass) {
        readonly FPackageIndex math = asset.TryFindImport("KismetMathLibrary", "Class") ?? AddScriptClass(asset, "KismetMathLibrary");
        readonly FPackageIndex system = asset.TryFindImport("KismetSystemLibrary", "Class") ?? AddScriptClass(asset, "KismetSystemLibrary");
        public FPackageIndex Function { get; private set; } = FPackageIndex.FromRawIndex(0);

        static FPackageIndex AddScriptClass(UAsset asset, string name) =>
            asset.FindOrAddImport("/Script/CoreUObject", "Class", asset.FindOrAddImport("/Script/CoreUObject", "Package", FPackageIndex.FromRawIndex(0), "/Script/Engine"), name);

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
        EX_CallMath Call(FPackageIndex library, string function, params KismetExpression[] parameters) =>
            new() { StackNode = asset.FindOrAddFunctionImport(library, function), Parameters = parameters };
        EX_CallMath Math(string function, params KismetExpression[] parameters) => Call(math, function, parameters);
        static EX_IntConst Int(int value) => new() { Value = value };
        KismetPropertyPointer Variable(string name) => PropertyPointer(asset.Name(name), coopConfigClass);
        EX_Context Member(Func<KismetExpression> config, string name) => MemberOf(config(), Variable(name));
        EX_Let Set(Func<KismetExpression> config, string name, KismetExpression value) =>
            new() { Value = Variable(name), Variable = Member(config, name), Expression = value };
        EX_JumpIfNot SkipIfNoConfig(Func<KismetExpression> config) => new() { BooleanExpression = Call(system, "IsValid", config()) };
        EX_CallMath PartyIndexIs(int slot) => Math("EqualEqual_IntInt", Local(PartyIndexLocal), Int(slot));

        // for each character:
        //   if (IsValid(Config)) { GetPartyIndexByName(Character, out PartyIndex, out InParty)
        //     if (InParty && Config-><Character>Assignment > 0)
        //       Config->Character<N>Assignment = PartyIndex == N - 1 ? Config-><Character>Assignment - 1 : Config->Character<N>Assignment }
        public void ApplyRemembered(FunctionExport func, int index, Func<KismetExpression> config, Func<string, KismetExpression> getPartyIndex) {
            foreach (var character in Characters) {
                var remembered = CharacterVariable(character);
                KismetExpression[] block = [
                    SkipIfNoConfig(config),
                    getPartyIndex(character),
                    new EX_JumpIfNot { BooleanExpression = Math("BooleanAND", Local(InPartyLocal), Math("Greater_IntInt", Member(config, remembered), Int(0))) },
                    ..Enumerable.Range(0, Slots).Select(slot => Set(config, SlotVariable(slot),
                        Math("SelectInt", Math("Subtract_IntInt", Member(config, remembered), Int(1)), Member(config, SlotVariable(slot)), PartyIndexIs(slot))))
                ];
                Splice(asset, func, index, 0, block, skipTarget: true);
                index += block.Length;
            }
        }

        // for each character:
        //   if (IsValid(Config)) { GetPartyIndexByName(Character, out PartyIndex, out InParty)
        //     if (InParty && PartyIndex < 3) Config-><Character>Assignment = Config->Character<PartyIndex + 1>Assignment + 1 }
        public void Remember(FunctionExport func, int index, Func<KismetExpression> config, Func<string, KismetExpression> getPartyIndex) {
            foreach (var character in Characters) {
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
