using UAssetAPI;
using UAssetAPI.ExportTypes;
using UAssetAPI.Kismet.Bytecode;
using UAssetAPI.Kismet.Bytecode.Expressions;
using static BlueprintPatching;

// With several local players CommonUI of player controller 0 keeps falling back to mouse and keyboard (prompts show keyboard keys, and the
// next gamepad press is spent switching back, e.g. A doesn't advance dialogue). Keep it on gamepad: every tick of player controller 0
//   GetLocalPlayerSubSystemFromPlayerController(self, CommonInputSubsystem)->SetCurrentInputType(Gamepad)
// SetCurrentInputType does nothing while the input type already is gamepad. Mouse and keyboard can't drive CommonUI menus with this patch.
public static class GamepadUiPatch {
    const byte Gamepad = 1; // ECommonInputType::Gamepad

    public static void PatchControllerWorld(UAsset controllerWorld) {
        var subsystemLibrary = controllerWorld.FindImport("SubsystemBlueprintLibrary", "Class");
        var commonInputSubsystem = controllerWorld.FindImport("CommonInputSubsystem", "Class");
        var getSubsystem = controllerWorld.FindOrAddFunctionImport(subsystemLibrary, "GetLocalPlayerSubSystemFromPlayerController");
        var setCurrentInputType = controllerWorld.FindOrAddFunctionImport(commonInputSubsystem, "SetCurrentInputType");

        var subsystem = new EX_CallMath { StackNode = getSubsystem, Parameters = [new EX_Self(), new EX_ObjectConst { Value = commonInputSubsystem }] };
        var call = new EX_FinalFunction { StackNode = setCurrentInputType, Parameters = [new EX_ByteConst { Value = Gamepad }] };
        var setGamepad = CallOn(controllerWorld, subsystem, call);
        // a missing subsystem must not log "Accessed None" every tick
        KismetExpression failSilent = new EX_Context_FailSilent {
            ObjectExpression = setGamepad.ObjectExpression,
            Offset = setGamepad.Offset,
            RValuePointer = setGamepad.RValuePointer,
            ContextExpression = setGamepad.ContextExpression
        };

        var func = (FunctionExport)controllerWorld["ReceiveTick"];
        Splice(controllerWorld, func, 0, 0, [failSilent]);
        controllerWorld.SyncNamesReferencedFromExportDataCount();
    }
}
