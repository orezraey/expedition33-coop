using UAssetAPI;
using UAssetAPI.Kismet.Bytecode;
using UAssetAPI.Kismet.Bytecode.Expressions;
using UAssetAPI.UnrealTypes;
using static BlueprintPatching;

// expressions shared by the patches of BP_jRPG_Controller_World
public sealed class ControllerWorldExpressions {
    readonly UAsset asset;
    readonly FPackageIndex getPlayerController, notPreBool, isValid, isInBattle;

    public FPackageIndex CoopControllerClass { get; }

    public ControllerWorldExpressions(UAsset controllerWorld) {
        asset = controllerWorld;
        var gameplayStatics = asset.FindImport("GameplayStatics", "Class");
        getPlayerController = asset.FindImport("GetPlayerController", outer: gameplayStatics);
        notPreBool = asset.FindImport("Not_PreBool", outer: asset.FindImport("KismetMathLibrary", "Class"));
        isValid = asset.FindImport("IsValid", outer: asset.FindImport("KismetSystemLibrary", "Class"));
        isInBattle = asset.ExportIndex("IsInBattle");
        CoopControllerClass = asset.FindOrAddBlueprintClassImport("/Game/Coop/CoopController", "CoopController_C");
    }

    // Cast<CoopController_C>(GetPlayerController(self, 1)): the first CoopController, which exists for the whole map
    public EX_DynamicCast CoopController() => new() {
        ClassPtr = CoopControllerClass,
        Target = new EX_CallMath { StackNode = getPlayerController, Parameters = [new EX_Self(), new EX_IntConst { Value = 1 }] }
    };

    // CoopController->ModActor->CoopConfig, the config ModLibrary::LoadCoopConfig returns while a CoopController exists
    public EX_Context CoopConfig() => MemberOf(
        MemberOf(CoopController(), PropertyPointer(asset.Name("ModActor"), CoopControllerClass)),
        PropertyPointer(asset.Name("CoopConfig"), asset.FindOrAddBlueprintClassImport("/Game/Coop/ModActor", "ModActor_C")));

    public FPackageIndex CoopConfigClass => asset.FindOrAddBlueprintClassImport("/Game/Coop/CoopConfig", "CoopConfig_C");

    public EX_CallMath IsValid(KismetExpression obj) => new() { StackNode = isValid, Parameters = [obj] };

    // jump unless no battle is running yet (BattleFlowState == 0)
    public EX_JumpIfNot SkipIfInBattle() => new() {
        BooleanExpression = new EX_CallMath { StackNode = notPreBool, Parameters = [new EX_LocalFinalFunction { StackNode = isInBattle, Parameters = [] }] }
    };

    // jump unless the CoopController exists, so contexts on it never access None
    public EX_JumpIfNot SkipIfNoCoopController() => new() { BooleanExpression = IsValid(CoopController()) };
}
