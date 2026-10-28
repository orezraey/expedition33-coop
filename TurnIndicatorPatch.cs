using UAssetAPI;
using UAssetAPI.ExportTypes;
using UAssetAPI.FieldTypes;
using UAssetAPI.Kismet.Bytecode;
using UAssetAPI.Kismet.Bytecode.Expressions;
using UAssetAPI.UnrealTypes;
using static BlueprintPatching;

// At the start of a player character's turn the mod only shows "Player {i}'s Turn" as a battle tooltip, which is easy to miss (with a random
// assignment players only noticed who controls a character when acting). Also show it with the mod's own UserSwitchWidget toast, the one
// shown when a player takes control with START. In BP_jRPG_Character_Battle_Base::OnTurnStart, right after controller 0 goes to the player:
//   Coop_TurnIndicator = SpawnObject(UserSwitchWidget_C, self)
//   SetTextPropertyByName(Coop_TurnIndicator, 'Text', "Player {i}'s Turn")
//   Coop_TurnIndicator->AddToViewport(9999)
public static class TurnIndicatorPatch {
    public static void PatchCharacterBattleBase(UAsset characterBattleBase) {
        var gameplayStatics = characterBattleBase.FindImport("GameplayStatics", "Class");
        var setPlayerPlatformUserId = characterBattleBase.FindImport("SetPlayerPlatformUserId", outer: gameplayStatics);
        var spawnObject = characterBattleBase.FindOrAddFunctionImport(gameplayStatics, "SpawnObject");
        var setTextPropertyByName = characterBattleBase.FindOrAddFunctionImport(characterBattleBase.FindImport("KismetSystemLibrary", "Class"), "SetTextPropertyByName");
        var userWidget = characterBattleBase.FindImport("UserWidget", "Class");
        var addToViewport = characterBattleBase.FindOrAddFunctionImport(userWidget, "AddToViewport");
        var userSwitchWidgetPackage = characterBattleBase.FindOrAddImport("/Script/CoreUObject", "Package", FPackageIndex.FromRawIndex(0), "/Game/Coop/UserSwitchWidget");
        var userSwitchWidget = characterBattleBase.FindOrAddImport("/Script/UMG", "WidgetBlueprintGeneratedClass", userSwitchWidgetPackage, "UserSwitchWidget_C");

        var func = (FunctionExport)characterBattleBase["OnTurnStart"];
        var funcIndex = characterBattleBase.ExportIndex("OnTurnStart");
        if (func.LoadedProperties.Any(p => p.Name.ToString() == "Coop_TurnIndicator"))
            throw new Exception("OnTurnStart is already patched");
        var template = (FObjectProperty)func.LoadedProperties.First(p => p.Name.ToString() == "K2Node_DynamicCast_AsBP_J_RPG_Controller_World");
        var indicator = CloneProperty(template, characterBattleBase.Name("Coop_TurnIndicator"));
        indicator.PropertyClass = userSwitchWidget;
        func.LoadedProperties = [..func.LoadedProperties, indicator];
        if (func.LoadedProperties.All(p => p.Name.ToString() != "CallFunc_Format_ReturnValue"))
            throw new Exception("OnTurnStart: turn text not found");

        // the hook calls SetPlayerPlatformUserId twice (primary, then the acting player); show the toast after the second one
        var switches = func.ScriptBytecode.Select((e, i) => (e, i)).Where(x => x.e is EX_CallMath call && call.StackNode.Index == setPlayerPlatformUserId.Index).ToList();
        if (switches.Count != 2)
            throw new Exception($"OnTurnStart: expected 2 SetPlayerPlatformUserId calls, found {switches.Count}");

        EX_LocalVariable Local(string name) => new() { Variable = PropertyPointer(characterBattleBase.Name(name), funcIndex) };
        KismetExpression[] toast = [
            new EX_LetObj {
                VariableExpression = Local("Coop_TurnIndicator"),
                AssignmentExpression = new EX_CallMath { StackNode = spawnObject, Parameters = [new EX_ObjectConst { Value = userSwitchWidget }, new EX_Self()] }
            },
            new EX_CallMath {
                StackNode = setTextPropertyByName,
                Parameters = [Local("Coop_TurnIndicator"), new EX_NameConst { Value = characterBattleBase.Name("Text") }, Local("CallFunc_Format_ReturnValue")]
            },
            CallOn(characterBattleBase, Local("Coop_TurnIndicator"),
                new EX_FinalFunction { StackNode = addToViewport, Parameters = [new EX_IntConst { Value = 9999 }] }, failSilent: true)
        ];
        Splice(characterBattleBase, func, switches[1].i + 1, 0, toast);
        characterBattleBase.SyncNamesReferencedFromExportDataCount();
    }
}
