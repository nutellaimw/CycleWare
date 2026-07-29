local CW = getgenv().__CW_CORE_STATE

local UserInputService = game:GetService("UserInputService")

local LocalPlayer = CW.LocalPlayer

if CW.IsFirstRun then
	LocalPlayer.AncestryChanged:Connect(function()
		if LocalPlayer:IsDescendantOf(game) then return end
		pcall(function() UserInputService.MouseIconEnabled=true end)
		pcall(function() UserInputService.MouseIcon="" end)
		pcall(function() CW.IAPortable:Destroy() end)
		pcall(function() if CW.State.enforcerConn then CW.State.enforcerConn:Disconnect() end end)
		pcall(function() if CW.State.enableConn   then CW.State.enableConn:Disconnect()   end end)
		CW.ActiveFollowClones = {}
	end)
end
