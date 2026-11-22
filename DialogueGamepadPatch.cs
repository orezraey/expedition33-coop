using UAssetAPI;
using UAssetAPI.ExportTypes;
using UAssetAPI.FieldTypes;
using UAssetAPI.Kismet.Bytecode;
using UAssetAPI.Kismet.Bytecode.Expressions;
using UAssetAPI.UnrealTypes;
using static BlueprintPatching;

// While player 2 owns player controller 0, CommonUI keeps falling back to mouse and keyboard: prompts show keyboard keys and A doesn't advance
// dialogue lines (the dialogue's Confirm is a CommonUI action). Forcing gamepad on every tick fixed dialogue, but in menus it released
// buttons mid-press and player 2 couldn't click anything (see the commit dropping GamepadUiPatch). Force it only while a dialogue line
// waits for Confirm: a dialogue is active, its container is the activated CommonUI widget (the overlay deactivates it when it hides) and it
// shows no choice buttons. In BP_jRPG_Controller_World::ReceiveTick, with Container = this.ExplorationHUDWidget->WBP_DialogueOverlay->WBP_DialogueContainer
// read fail-silent (no HUD in some scenes):
//   Coop_InDialogue = this.BP_DialogueSystemComponent->HasActiveDialogue()
//   if (Coop_InDialogue) {
//     Coop_InDialogue = Container->IsActivated()
//     if (Coop_InDialogue) {
//       Coop_Choices = Array_Length(Container->CurrentChoiceWidgets)
//       if (Coop_Choices == 0) GetLocalPlayerSubSystemFromPlayerController(self, CommonInputSubsystem)->SetCurrentInputType(Gamepad)
//   } }
public static class DialogueGamepadPatch {
    const byte Gamepad = 1; // ECommonInputType::Gamepad
    const string InDialogueLocal = "Coop_InDialogue";
    const string ChoicesLocal = "Coop_Choices";

    public static void PatchControllerWorld(UAsset controllerWorld) {
        var func = (FunctionExport)controllerWorld["ReceiveTick"];
        var funcIndex = controllerWorld.ExportIndex("ReceiveTick");
        if (func.LoadedProperties.Any(p => p.Name.ToString() is InDialogueLocal or ChoicesLocal))
            throw new Exception("ReceiveTick is already patched for dialogue");
        var functions = controllerWorld.Exports.OfType<FunctionExport>().ToList();
        FProperty Template(Func<FProperty, bool> match, string kind) =>
            functions.SelectMany(f => f.LoadedProperties).FirstOrDefault(p => match(p) && !p.PropertyFlags.HasFlag(EPropertyFlags.CPF_Parm))
            ?? throw new Exception($"Controller_World has no {kind} local to clone");
        var inDialogue = CloneProperty(Template(p => p is FBoolProperty, "bool"), controllerWorld.Name(InDialogueLocal));
        var choices = CloneProperty(Template(p => p.SerializedType?.ToString() == "IntProperty", "int"), controllerWorld.Name(ChoicesLocal));
        inDialogue.PropertyFlags = choices.PropertyFlags = EPropertyFlags.CPF_None;
        func.LoadedProperties = [..func.LoadedProperties, inDialogue, choices];
        KismetPropertyPointer Local(string name) => PropertyPointer(controllerWorld.Name(name), funcIndex);

        // this.BP_DialogueSystemComponent->HasActiveDialogue(), as the game calls it elsewhere in this class
        var hasActiveDialogue = functions.SelectMany(f => f.ScriptBytecode ?? []).OfType<EX_LetBool>()
            .Select(let => let.AssignmentExpression).OfType<EX_Context>()
            .FirstOrDefault(c => c.ObjectExpression is EX_InstanceVariable { Variable: var v } && v.New.Path[0].ToString() == "BP_DialogueSystemComponent" &&
                                 c.RValuePointer.New.Path[0].ToString().StartsWith("CallFunc_HasActiveDialogue"))
            ?? throw new Exception("Controller_World: HasActiveDialogue call not found");
        // this.ExplorationHUDWidget->WBP_DialogueOverlay, as GetDialogueOverlay reads it
        var overlay = ((EX_LetObj)((FunctionExport)controllerWorld["GetDialogueOverlay"]).ScriptBytecode[0]).AssignmentExpression as EX_Context
            ?? throw new Exception("Controller_World: GetDialogueOverlay doesn't read the HUD's dialogue overlay");

        var overlayClass = controllerWorld.FindImport("WBP_DialogueOverlay_C", "WidgetBlueprintGeneratedClass");
        var containerClass = controllerWorld.FindOrAddImport("/Script/UMG", "WidgetBlueprintGeneratedClass",
            controllerWorld.FindOrAddImport("/Script/CoreUObject", "Package", FPackageIndex.FromRawIndex(0), "/Game/UI/Widgets/DialogueSystem/WBP_DialogueContainer"),
            "WBP_DialogueContainer_C");
        EX_Context_FailSilent Silent(EX_Context context) => new() {
            ObjectExpression = context.ObjectExpression, Offset = context.Offset, RValuePointer = context.RValuePointer, ContextExpression = context.ContextExpression
        };
        EX_Context_FailSilent Container() => Silent(MemberOf(Silent(overlay), PropertyPointer(controllerWorld.Name("WBP_DialogueContainer"), overlayClass)));
        var currentChoices = Silent(MemberOf(Container(), PropertyPointer(controllerWorld.Name("CurrentChoiceWidgets"), containerClass)));
        var activatableWidget = controllerWorld.FindOrAddImport("/Script/CoreUObject", "Class",
            controllerWorld.FindOrAddImport("/Script/CoreUObject", "Package", FPackageIndex.FromRawIndex(0), "/Script/CommonUI"), "CommonActivatableWidget");
        var isActivated = CallOn(controllerWorld, Container(),
            new EX_FinalFunction { StackNode = controllerWorld.FindOrAddFunctionImport(activatableWidget, "IsActivated"), Parameters = [] }, failSilent: true);
        isActivated.RValuePointer = Local(InDialogueLocal);
        var arrayLength = CallOn(controllerWorld, new EX_ObjectConst { Value = controllerWorld.FindImport("Default__KismetArrayLibrary") },
            new EX_FinalFunction { StackNode = controllerWorld.FindImport("Array_Length", outer: controllerWorld.FindImport("KismetArrayLibrary", "Class")), Parameters = [currentChoices] });
        arrayLength.RValuePointer = Local(ChoicesLocal);

        var subsystemLibrary = controllerWorld.FindImport("SubsystemBlueprintLibrary", "Class");
        var commonInputSubsystem = controllerWorld.FindImport("CommonInputSubsystem", "Class");
        var subsystem = new EX_CallMath {
            StackNode = controllerWorld.FindOrAddFunctionImport(subsystemLibrary, "GetLocalPlayerSubSystemFromPlayerController"),
            Parameters = [new EX_Self(), new EX_ObjectConst { Value = commonInputSubsystem }]
        };
        var setGamepad = new EX_FinalFunction {
            StackNode = controllerWorld.FindOrAddFunctionImport(commonInputSubsystem, "SetCurrentInputType"),
            Parameters = [new EX_ByteConst { Value = Gamepad }]
        };
        var math = controllerWorld.FindImport("KismetMathLibrary", "Class");

        KismetExpression[] block = [
            new EX_LetBool {
                VariableExpression = new EX_LocalVariable { Variable = Local(InDialogueLocal) },
                AssignmentExpression = new EX_Context {
                    ObjectExpression = hasActiveDialogue.ObjectExpression, Offset = hasActiveDialogue.Offset,
                    RValuePointer = Local(InDialogueLocal), ContextExpression = hasActiveDialogue.ContextExpression
                }
            },
            new EX_JumpIfNot { BooleanExpression = new EX_LocalVariable { Variable = Local(InDialogueLocal) } },
            new EX_LetBool { VariableExpression = new EX_LocalVariable { Variable = Local(InDialogueLocal) }, AssignmentExpression = isActivated },
            new EX_JumpIfNot { BooleanExpression = new EX_LocalVariable { Variable = Local(InDialogueLocal) } },
            new EX_Let { Value = Local(ChoicesLocal), Variable = new EX_LocalVariable { Variable = Local(ChoicesLocal) }, Expression = arrayLength },
            new EX_JumpIfNot {
                BooleanExpression = new EX_CallMath {
                    StackNode = controllerWorld.FindOrAddFunctionImport(math, "EqualEqual_IntInt"),
                    Parameters = [new EX_LocalVariable { Variable = Local(ChoicesLocal) }, new EX_IntConst { Value = 0 }]
                }
            },
            // a missing subsystem must not log "Accessed None" every tick
            CallOn(controllerWorld, subsystem, setGamepad, failSilent: true)
        ];
        Splice(controllerWorld, func, 0, 0, block, skipTarget: true);
        controllerWorld.SyncNamesReferencedFromExportDataCount();
    }
}
