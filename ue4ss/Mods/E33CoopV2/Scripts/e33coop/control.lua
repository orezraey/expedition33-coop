-- Unified PC0 ownership state machine.
-- Replaces ControlRestorePatch's scattered splices, CDO hacks, and ReceiveTick polling
-- with a single explicit state machine driven by game lifecycle events.

local Log = require("e33coop.log")
local Roster = require("e33coop.roster")

local Control = {}

function Control.new(ue, config, gamepad)
    local self = {
        -- PlatformUserId.InternalId of the player exploring outside battle (persists across map changes in Lua)
        explorationUserId = nil,
        -- If ModActor::ReceiveBeginPlay ran before CoopControllers finished spawning, retry restore as soon as they exist
        pendingMapRestoreUserId = nil,
        inBattle = false,
        battleEndState = Roster.BATTLE_END_NONE,
        battleEndHandedOver = false,
        -- PlatformUserId.InternalId that should currently own PC0 during an active battle
        expectedBattleUserId = nil,
    }

    local function primaryId()
        local _, id = ue.getPrimaryPlatformUser()
        return id or 0
    end

    local function ensureExplorationUserInitialized()
        if self.explorationUserId == nil then
            local pc0 = ue.getPlayerController(0)
            self.explorationUserId = ue.getPlatformUserId(pc0) or primaryId()
        end
        return self.explorationUserId
    end

    -- Every PC0 owner change also re-applies the cursor: hidden for P2/P3, the game's own for P1.
    local function setPC0(targetUserId, reason)
        local ok = ue.setController0User(targetUserId, reason)
        if ok then
            gamepad.syncCursorVisibility(reason)
        end
        return ok
    end

    function self.isInBattle()
        return self.inBattle
    end

    function self.getExplorationUserId()
        return self.explorationUserId
    end

    function self.tryPendingMapRestore(source)
        local target = self.pendingMapRestoreUserId
        if target == nil or self.inBattle then
            return false
        end
        if setPC0(target, "map_restore:" .. tostring(source)) then
            self.pendingMapRestoreUserId = nil
            Log.info("Restored exploration control to user %s (%s)", tostring(target), tostring(source))
            gamepad.onMapReady()
            return true
        end
        return false
    end

    -- Called once per map when ModActor::ReceiveBeginPlay runs.
    function self.onMapReady()
        self.inBattle = false
        self.battleEndState = Roster.BATTLE_END_NONE
        self.battleEndHandedOver = false
        self.expectedBattleUserId = nil
        gamepad.resetButtonState()

        if self.explorationUserId ~= nil then
            self.pendingMapRestoreUserId = self.explorationUserId
            if not self.tryPendingMapRestore("map_ready") then
                Log.info("Map ready: deferring exploration restore to user %s until CoopControllers finish spawning",
                    tostring(self.explorationUserId))
                gamepad.onMapReady()
            end
        else
            ensureExplorationUserInitialized()
            gamepad.onMapReady()
        end
    end

    -- Called POST after ModActor::SetupCoopController creates a CoopController on the new map.
    function self.onCoopControllerReady()
        self.tryPendingMapRestore("setup_coop_controller")
    end

    -- Called after BP_jRPG_Controller_World::PrepareToChangeMap runs (Blueprint hooks are post-hooks).
    -- The base mod's PrepareToChangeMap hands PC0 to PrimaryUser BEFORE calling the original, so PC0
    -- no longer tells who was exploring here: keep the explorer tracked by START takeovers and battles.
    function self.onPrepareToChangeMap()
        ensureExplorationUserInitialized()
        Log.info("Map changing (inBattle=%s): preserving exploration user %s",
            tostring(self.inBattle), tostring(self.explorationUserId))
        self.inBattle = false
        self.battleEndState = Roster.BATTLE_END_NONE
        self.battleEndHandedOver = false
        self.expectedBattleUserId = nil
        self.pendingMapRestoreUserId = nil
        gamepad.resetButtonState()
    end

    -- Called POST after CoopController handles START (Gamepad_Special_Right).
    -- In exploration or on Victory/Flee screens, accept the takeover and update explorationUserId.
    -- During active battle, optionally undo accidental takeover so defense routing stays intact.
    function self.onStartTakeover()
        local pc0 = ue.getPlayerController(0)
        if not pc0 then
            return
        end

        if self.inBattle and not self.battleEndHandedOver and config.shouldBlockStartInBattle() then
            local restoreTo = self.expectedBattleUserId or primaryId()
            Log.info("Blocked START takeover during active battle; keeping PC0 on user %s", tostring(restoreTo))
            setPC0(restoreTo, "block_start_in_battle")
            return
        end

        local newOwner = ue.getPlatformUserId(pc0)
        if newOwner ~= nil then
            self.pendingMapRestoreUserId = nil
            self.explorationUserId = newOwner
            Log.info("START takeover accepted: exploration user is now %s", tostring(newOwner))
            gamepad.ensureGamepadIfSafe("start_takeover")
            gamepad.syncCursorVisibility("start_takeover")
        end
    end

    -- Called when BP_jRPG_Controller_World::OnBattleBeginTransitionRequested runs.
    -- Guarded by `not self.inBattle` so chained battles keep the pre-battle exploration user.
    function self.onBattleBegin()
        if self.inBattle then
            Log.debug("Chained battle transition detected; preserving exploration user %s",
                tostring(self.explorationUserId))
            return
        end

        local pc0 = ue.getPlayerController(0)
        local current = ue.getPlatformUserId(pc0)
        if current ~= nil then
            self.explorationUserId = current
        else
            ensureExplorationUserInitialized()
        end

        self.inBattle = true
        self.battleEndState = Roster.BATTLE_END_NONE
        self.battleEndHandedOver = false

        -- Reset stale BattleEndState from any previous battle
        local bm = ue.getBattleManager()
        if bm then
            pcall(function() bm.BattleEndState = Roster.BATTLE_END_NONE end)
        end

        config.rollForBattle()

        -- Hand PC0 to PrimaryUser right away: if enemies act first, P1's characters defend via PC0
        -- while P2/P3 defend via CoopController.
        local p1 = primaryId()
        self.expectedBattleUserId = p1
        setPC0(p1, "battle_begin")
        Log.info("Battle began: saved exploration user=%s, handed PC0 to primary user=%s",
            tostring(self.explorationUserId), tostring(p1))
    end

    -- Called when a player character's turn starts.
    function self.onPlayerTurnStart(targetUserId, playerIndex, charId)
        if not self.inBattle then
            -- Defensive recovery if we missed OnBattleBeginTransitionRequested (e.g. hot reload mid-battle)
            self.inBattle = true
            ensureExplorationUserInitialized()
        end
        if self.battleEndHandedOver then
            return
        end
        self.expectedBattleUserId = targetUserId
        setPC0(targetUserId, "player_turn:" .. tostring(charId))
        gamepad.ensureGamepadIfSafe("player_turn")
    end

    -- Called when an enemy character's turn starts.
    -- Guarantees PC0 is on PrimaryUser even if a player turn ended without firing OnTurnEnded.
    function self.onEnemyTurnStart()
        if not self.inBattle or self.battleEndHandedOver then
            return
        end
        local p1 = primaryId()
        self.expectedBattleUserId = p1
        setPC0(p1, "enemy_turn")
    end

    -- Called POST after BP_jRPG_Character_Battle_Base::OnTurnEnded runs.
    -- The unpatched mod always resets PC0 to PrimaryUser in OnTurnEnded; if the battle has
    -- already ended or handed over to Victory/Flee, immediately restore the exploration user.
    function self.onTurnEnded(isPlayerCharacter)
        if not isPlayerCharacter then
            return
        end
        if (not self.inBattle) or self.battleEndHandedOver then
            local target = ensureExplorationUserInitialized()
            setPC0(target, "late_turn_end_restore")
            gamepad.ensureGamepadIfSafe("late_turn_end_restore")
        else
            -- the base mod just handed PC0 back to PrimaryUser
            self.expectedBattleUserId = primaryId()
            gamepad.syncCursorVisibility("turn_ended")
        end
    end

    -- Event-driven Victory / Flee handover via AC_jRPG_BattleManager::StartBattleEndFlow.
    -- One-shot: hands PC0 to the exploration user once, without fighting START on every tick.
    function self.onBattleEndFlowStarted(resultByte)
        self.battleEndState = resultByte or Roster.BATTLE_END_NONE
        if self.battleEndState == Roster.BATTLE_END_WON or self.battleEndState == Roster.BATTLE_END_FLED then
            if not self.battleEndHandedOver then
                self.battleEndHandedOver = true
                local target = ensureExplorationUserInitialized()
                Log.info("Battle end flow (%d): handing Victory/Flee screen to user %s",
                    self.battleEndState, tostring(target))
                setPC0(target, "battle_end_flow")
                gamepad.ensureGamepadIfSafe("battle_end_flow")
            end
        elseif self.battleEndState == Roster.BATTLE_END_LOST then
            -- Keep PrimaryUser on Game Over / Reserve Team screen
            local p1 = primaryId()
            self.expectedBattleUserId = p1
            setPC0(p1, "battle_lost_flow")
        end
    end

    -- Called POST after BP_jRPG_Controller_World::ResumeExplorationOnBattleEnd runs.
    function self.onBattleEnd(resultByte)
        if resultByte == Roster.BATTLE_END_LOST then
            config.markRetryKeepRoll()
        end
        self.inBattle = false
        self.battleEndState = Roster.BATTLE_END_NONE
        self.battleEndHandedOver = false
        self.expectedBattleUserId = nil

        local target = ensureExplorationUserInitialized()
        Log.info("Battle ended (result=%s): restoring exploration user %s",
            tostring(resultByte), tostring(target))
        setPC0(target, "battle_end")
        gamepad.ensureGamepadIfSafe("battle_end")
    end

    return self
end

return Control
