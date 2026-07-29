local CW = getgenv().__CW_CORE_STATE

local Players      = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local LocalPlayer = CW.LocalPlayer

if CW.IsFirstRun then
	CW.Bindable = Instance.new("BindableEvent")

	CW.Bindable.Event:Connect(function(bullets)
	local ShotHit = false
	for _, bullet in pairs(bullets) do
		local Hit = bullet[3]
		if not Hit or not Hit.Parent then continue end
		local ok, isHit = pcall(function()
			local Player = Players:GetPlayerFromCharacter(Hit.Parent)
				or (Hit.Parent.Parent and Players:GetPlayerFromCharacter(Hit.Parent.Parent))
			return Player and Player ~= LocalPlayer and Player.TeamColor ~= CW.State.cachedTeamColor
		end)
		if ok and isHit then
			ShotHit = true
			break
		end
	end
	if not ShotHit then return end
		CW.playHitSound()

		local Clone = CW.HMTemplate:Clone()
		Clone.Size              = UDim2.new(0, CW.Settings.HITMARKER_SIZE, 0, CW.Settings.HITMARKER_SIZE)
		Clone.Position           = UDim2.fromOffset(CW.State.mouseX, CW.State.mouseY)
		Clone.Rotation           = CW.Settings.HITMARKER_RANDOM_ROTATION and math.random(0,90) or 0
		Clone.ImageTransparency = 0
		Clone.Parent             = CW.IAPortable

		if CW.Settings.HITMARKER_FOLLOW_MOUSE then
			CW.ActiveFollowClones[Clone] = true
		end

		local function finishClone()
			CW.ActiveFollowClones[Clone] = nil
			if Clone.Parent then Clone:Destroy() end
		end

		task.delay(CW.Settings.HITMARKER_VISIBLE_DURATION, function()
			if not Clone.Parent then return end

			if CW.Settings.HITMARKER_FADEOUT then
				local baseSize = Clone.Size
				local growSize = UDim2.new(
					0, baseSize.X.Offset * 1.35,
					0, baseSize.Y.Offset * 1.35
				)

				local ok = pcall(function()
					local tween = TweenService:Create(
						Clone,
						TweenInfo.new(
							CW.Settings.HITMARKER_FADEOUT_DURATION,
							Enum.EasingStyle.Quad,
							Enum.EasingDirection.Out
						),
						{ ImageTransparency = 1, Size = growSize }
					)
					tween.Completed:Connect(finishClone)
					tween:Play()
				end)
				if not ok then finishClone() end
			else
				finishClone()
			end
		end)
	end)

	local OldNameCall
	OldNameCall = hookmetamethod(CW.ShootEvent, "__namecall", newcclosure(function(self, ...)
		if checkcaller() then return OldNameCall(self, ...) end
		if getnamecallmethod() == "FireServer" and self == CW.ShootEvent then
			CW.Bindable.Fire(CW.Bindable, ...)
		end
		return OldNameCall(self, ...)
	end))
end
