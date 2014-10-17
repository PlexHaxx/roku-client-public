'*****************************************************************
'**  Home screen: the entry display of the application
'**
'*****************************************************************

Function createHomeScreen(viewController) As Object
    ' At the end of the day, the home screen is just a grid with a custom loader.
    ' So create a regular grid screen and override/extend as necessary.
    obj = createGridScreen(viewController, "flat-square")

    ' do not exit with the up button on the home screen
    obj.screen.SetUpBehaviorAtTopRow("stop")
    obj.Screen.SetDisplayMode("photo-fit")
    obj.Loader = createHomeScreenDataLoader(obj)

    obj.Refresh = refreshHomeScreen
    obj.OnTimerExpired = homeScreenOnTimerExpired
    obj.SuperActivate = obj.Activate
    obj.Activate = homeScreenActivate
    obj.SetBreadCrumbs = homeScreenSetBreadcrumbs

    obj.clockTimer = createTimer()
    obj.clockTimer.Name = "clock"
    obj.clockTimer.SetDuration(20000, true) ' A little lag is fine here
    viewController.AddTimer(obj.clockTimer, obj)

    return obj
End Function

Sub refreshHomeScreen(changes)
    PrintAA(changes)

    ' If myPlex state changed, we need to update the queue, shared sections,
    ' and any owned servers that were discovered through myPlex.
    if changes.DoesExist("myplex") then
        m.Loader.OnMyPlexChange()
    end if

    ' If a server was added or removed, we need to update the sections,
    ' channels, and channel directories.
    if changes.DoesExist("servers") then
        for each server in PlexMediaServers()
            if server.machineID <> invalid AND GetPlexMediaServer(server.machineID) = invalid then
                PutPlexMediaServer(server)
            end if
        next

        servers = changes["servers"]
        for each machineID in servers
            Debug("Server " + tostr(machineID) + " was " + tostr(servers[machineID]))
            if servers[machineID] = "removed" then
                DeletePlexMediaServer(machineID)
            end if
        next

        m.Loader.OnServersChange()
    end if

    ' Recompute our capabilities
    Capabilities(true)
End Sub

Sub homeScreenOnTimerExpired(timer)
    if timer.Name = "clock" AND m.ViewController.IsActiveScreen(m) then
        m.SetBreadcrumbs()
    else if timer.Name = "gridRowVisibilityChange" then
        gridCloseRowVisibilityFacade(timer)
    end if
End Sub

Sub homeScreenActivate(priorScreen)
    m.clockTimer.Active = (RegRead("home_clock_display", "preferences", "12h") <> "off")
    m.SetBreadcrumbs()
    m.SuperActivate(priorScreen)
End Sub

Sub homeScreenSetBreadcrumbs()
    if MyPlexManager().homeUsers.count() > 0 then
        userInfo = firstOf(MyPlexManager().Title, "")
    else
        userInfo = ""
    end if
    m.Screen.SetBreadcrumbEnabled(true)
    m.Screen.SetBreadcrumbText(userInfo, CurrentTimeAsString())
End Sub
