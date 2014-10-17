'*
'* Utilities related to signing in to myPlex and making myPlex requests
'*

Function MyPlexManager() As Object
    if m.MyPlexManager = invalid then
        ' Start by creating a PlexMediaServer since we can't otherwise inherit
        ' anything. Then tweak as appropriate.
        obj = newPlexMediaServer("https://staging.plex.tv", "myPlex", "myplex")

        AppManager().AddInitializer("myplex")

        obj.CreateRequest = mpCreateRequest
        obj.ValidateToken = mpValidateToken
        obj.Disconnect = mpDisconnect

        obj.ExtraHeaders = {}
        obj.ExtraHeaders["X-Plex-Provides"] = "player"

        ' Masquerade as a basic Plex Media Server
        obj.owned = false
        obj.online = true
        obj.StopVideo = mpStopVideo
        obj.StartTranscode = mpStartTranscode
        obj.PingTranscode = mpPingTranscode
        obj.TranscodedImage = mpTranscodedImage
        obj.TranscodingVideoUrl = mpTranscodingVideoUrl
        obj.GetQueryResponse = mpGetQueryResponse
        obj.Log = mpLog
        obj.AllowsMediaDeletion = false
        obj.SupportsMultiuser = false
        obj.SupportsVideoTranscoding = true

        ' Commands, mostly use the PMS functions
        obj.Delete = mpDelete
        obj.ExecuteCommand = mpExecuteCommand
        obj.ExecutePostCommand = mpExecutePostCommand

        obj.IsSignedIn = false
        obj.IsPlexPass = false
        obj.Username = invalid
        obj.EmailAddress = invalid
        obj.RefreshAccountInfo = mpRefreshAccountInfo

        obj.TranscodeServer = invalid
        obj.CheckTranscodeServer = mpCheckTranscodeServer

        obj.ProcessAccountResponse = mpProcessAccountResponse
        obj.Publish = mpPublish

        ' For using the view controller for HTTP requests
        obj.ScreenID = -5
        obj.OnUrlEvent = mpOnUrlEvent

        ' Home Users
        obj.homeUsers = createObject("roList")
        obj.UpdateHomeUsers = mpUpdateHomeUsers
        obj.SwitchHomeUser = mpSwitchHomeUser

        ' Singleton
        m.MyPlexManager = obj

        ' Kick off initialization
        token = RegRead("AuthToken", "myplex")
        if token <> invalid then
            obj.ValidateToken(token, true)
        else
            AppManager().ClearInitializer("myplex")
        end if
    end if

    return m.MyPlexManager
End Function

Sub mpRefreshAccountInfo()
    if m.AuthToken <> invalid then
        dialog = CreateObject("roOneLineDialog")
        dialog.ShowBusyAnimation()
        dialog.Show()

        m.ValidateToken(m.AuthToken, false)

        dialog.Close()
    end if
End Sub

Function mpValidateToken(token, async) As Boolean
    req = m.CreateRequest("", "/users/account", false)
    req.AddHeader("X-Plex-Token", token)

    if async then
        context = CreateObject("roAssociativeArray")
        context.requestType = "account"
        GetViewController().StartRequest(req, m, context)
    else
        port = CreateObject("roMessagePort")
        req.SetPort(port)
        req.AsyncGetToString()

        event = wait(10000, port)
        m.ProcessAccountResponse(event)
    end if

    return m.IsSignedIn
End Function

Sub mpOnUrlEvent(msg, requestContext)
    if requestContext.requestType = "account" then
        m.ProcessAccountResponse(msg)
        AppManager().ClearInitializer("myplex")
    end if
End Sub

Sub mpProcessAccountResponse(event)
    if type(event) = "roUrlEvent" AND event.GetInt() = 1 AND event.GetResponseCode() = 200 then
        xml = CreateObject("roXMLElement")
        xml.Parse(event.GetString())
        m.Id = xml@id
        m.Username = xml@username
        m.EmailAddress = xml@email
        m.Title = xml@title
        m.IsSignedIn = true
        m.AuthToken = xml@authenticationToken
        m.IsPlexPass = (xml.subscription <> invalid AND xml.subscription@active = "1")
        m.Protected = false
        m.Admin = false

        m.IsEntitled = false
        if xml.entitlements <> invalid then
            if tostr(xml.entitlements@all) = "1" then
                m.IsEntitled = true
            else
                for each entitlement in xml.entitlements.GetChildElements()
                    if ucase(tostr(entitlement@id)) = "ROKU" then
                        m.IsEntitled = true
                        exit for
                    end if
                end for
            end if
        end if

        if m.IsEntitled then
            RegWrite("IsEntitled", "1", "misc")
        else
            RegWrite("IsEntitled", "0", "misc")
        end if

        if m.IsPlexPass then
            RegWrite("IsPlexPass", "1", "misc")
        else
            RegWrite("IsPlexPass", "0", "misc")
        end if
        Debug("Validated myPlex token, corresponds to " + tostr(m.Id) + ":" + tostr(m.Title))
        Debug("PlexPass: " + tostr(m.IsPlexPass))
        Debug("Entitlement: " + tostr(m.IsEntitled))

        mgr = AppManager()
        mgr.IsPlexPass = m.IsPlexPass
        mgr.IsEntitled = m.IsEntitled
        mgr.ResetState()

        m.Publish()

        ' update the list of users in the home
        m.UpdateHomeUsers()

        ' set the users protected and admin keys
        if m.homeUsers.count() > 0 then
            for each user in m.homeUsers
                if m.id = user.id then
                    m.Protected = (tostr(user.protected) = "1")
                    m.Admin = (tostr(user.admin) = "1")
                    exit for
                end if
            end for
        end if

        ' reset the current admin state
        GetGlobalAA().AddReplace("IsAdmin", m.Admin)

        ' reset registry user
        RegInitializeUser()
    else
        Debug("Failed to validate myPlex token")
        m.IsSignedIn = false
    end if
End Sub

Sub mpPublish()
    context = CreateObject("roAssociativeArray")
    context.requestType = "publish"

    url = "/devices/" + GetGlobal("rokuUniqueID")
    device = CreateObject("roDeviceInfo")
    addrs = device.GetIPAddrs()
    first = true
    for each iface in addrs
        if first then
            first = false
            url = url + "?"
        else
            url = url + "&"
        end if
        url = url + HttpEncode("Connection[][uri]") + "=" + HttpEncode("http://" + addrs[iface] + ":8324")
    end for

    req = m.CreateRequest("", url)
    GetViewController().StartRequest(req, m, context, "_method=PUT")
End Sub

Function mpCreateRequest(sourceUrl As String, path As String, appendToken=true As Boolean, connectionUrl=invalid) As Object
    url = FullUrl(m.serverUrl, sourceUrl, path)
    req = CreateURLTransferObject(url)
    if appendToken AND m.AuthToken <> invalid then
        if Instr(1, url, "?") > 0 then
            req.SetUrl(url + "&auth_token=" + m.AuthToken)
        else
            req.SetUrl(url + "?auth_token=" + m.AuthToken)
        end if
    end if
    for each name in m.ExtraHeaders
        req.AddHeader(name, m.ExtraHeaders[name])
    next
    req.AddHeader("Accept", "application/xml")
    req.SetCertificatesFile("common:/certs/ca-bundle.crt")
    return req
End Function

Sub mpDisconnect()
    RegDelete("AuthToken", "myplex")
    ' remove all auth tokens for any server
    RegDeleteSection("server_tokens")
    ' reset the current admin state
    GetGlobalAA().AddReplace("IsAdmin", true)

    ' reset the MyPlexManager singleton
    GetGlobalAA().Delete("MyPlexManager")
    MyPlexManager()

    ' reset registry user
    RegInitializeUser()
End Sub

Function mpCheckTranscodeServer(showError=false As Boolean) As Boolean
    if m.TranscodeServer = invalid then
        m.TranscodeServer = GetPrimaryServer()
    end if

    if m.TranscodeServer = invalid then
        if showError then
            dlg = createBaseDialog()
            dlg.Title = "Unsupported Content"
            dlg.Text = "Your Roku needs a bit of help to play this. This video is in a format that your Roku doesn't understand. To play it, you need to connect to your Plex Media Server, which can convert it in real time to a more friendly format. To learn more and install Plex Media Server, visit https://plex.tv/downloads"
            dlg.Show(true)
        end if
        Debug("myPlex operation failed due to lack of primary server")
        return false
    else
        m.SupportsVideoTranscoding = m.TranscodeServer.SupportsVideoTranscoding
    end if

    return true
End Function

Function mpTranscodingVideoUrl(videoUrl As String, item As Object, httpHeaders As Object, seekValue=0)
    if NOT m.CheckTranscodeServer(true) then return invalid

    return m.TranscodeServer.TranscodingVideoUrl(videoUrl, item, httpHeaders, seekValue)
End Function

Function mpStartTranscode(videoUrl)
    if NOT m.CheckTranscodeServer() then return ""

    return m.TranscodeServer.StartTranscode(videoUrl)
End Function

Function mpStopVideo()
    if NOT m.CheckTranscodeServer() then return invalid

    return m.TranscodeServer.StopVideo()
End Function

Function mpPingTranscode()
    if NOT m.CheckTranscodeServer() then return invalid

    return m.TranscodeServer.PingTranscode()
End Function

Function mpTranscodedImage(queryUrl, imagePath, width, height) As String
    if Left(imagePath, 5) = "https" then
        imagePath = "http" +  Mid(imagePath, 6, len(imagePath) - 5)
    end if

    if m.CheckTranscodeServer() then
        return m.TranscodeServer.TranscodedImage(queryUrl, imagePath, width, height)
    else if Left(imagePath, 4) = "http" then
        return imagePath
    else
        Debug("Don't know how to transcode image: " + tostr(queryUrl) + ", " + tostr(imagePath))
        return ""
    end if
End Function

Sub mpDelete(id)
    if id <> invalid then
        commandUrl = m.serverUrl + "/pms/playlists/queue/items/" + id
        Debug("Executing delete command: " + commandUrl)
        request = m.CreateRequest("", commandUrl)
        request.PostFromString("_method=DELETE")
    end if
End Sub

Function mpExecuteCommand(commandPath)
    commandUrl = m.serverUrl + "/pms" + commandPath
    Debug("Executing command with full command URL: " + commandUrl)
    request = m.CreateRequest("", commandUrl)
    request.AsyncGetToString()

    GetGlobalAA().AddReplace("async_command", request)
End Function

Function mpExecutePostCommand(commandPath)
    commandUrl = m.serverUrl + "/pms" + commandPath
    Debug("Executing POST command with full command URL: " + commandUrl)
    request = m.CreateRequest("", commandUrl)
    request.AsyncPostFromString("")

    GetGlobalAA().AddReplace("async_command", request)
End Function

Function mpGetQueryResponse(sourceUrl, key) As Object
    xmlResult = CreateObject("roAssociativeArray")
    xmlResult.server = m
    httpRequest = m.CreateRequest(sourceUrl, key)
    Debug("Fetching content from server at query URL: " + tostr(httpRequest.GetUrl()))
    response = GetToStringWithTimeout(httpRequest, 60)
    xml=CreateObject("roXMLElement")
    if not xml.Parse(response) then
        Debug("Can't parse feed: " + tostr(response))
    endif

    xmlResult.xml = xml
    xmlResult.sourceUrl = httpRequest.GetUrl()

    return xmlResult
End Function

Sub mpLog(msg="", level=3, timeout=0)
    ' Noop, only defined to implement PlexMediaServer "interface"
End Sub

function mpUpdateHomeUsers() as boolean
    req = m.CreateRequest("", "/api/home/users")

    port = CreateObject("roMessagePort")
    req.SetPort(port)
    req.AsyncGetToString()

    event = wait(10000, port)
    if type(event) = "roUrlEvent" and event.GetInt() = 1 and event.GetResponseCode() = 200 then
        xml = CreateObject("roXMLElement")
        xml.Parse(event.GetString())
        m.homeUsers.clear()
        if firstOf(xml@size, "0").toInt() and xml.user <> invalid then
            for each user in xml.user
                m.homeUsers.push(user.GetAttributes())
            end for
        end if
    end if

    Debug("home users total: " + tostr(m.homeUsers.count()))
end function

function mpSwitchHomeUser(userId as string, pin="" as dynamic) as boolean
    ' build path and post to myplex to swith the user
    path = "/api/home/users/" + userid + "/switch"
    req = m.CreateRequest("", path)
    port = CreateObject("roMessagePort")
    req.SetPort(port)
    req.AsyncPostFromString("pin=" + pin)

    event = wait(10000, port)
    if type(event) = "roUrlEvent" and event.GetInt() = 1 and event.GetResponseCode() = 201 then
        xml = CreateObject("roXMLElement")
        xml.Parse(event.GetString())
        if xml@authenticationToken <> invalid and m.ValidateToken(xml@authenticationToken, false) then
            ' remove all auth tokens for any server
            RegDeleteSection("server_tokens")

            if pin <> "" then m.PinAuthenticated = true
            RegWrite("AuthToken", xml@authenticationToken, "myplex")

            ' refresh the home screen if it exists
            home = GetViewController().home
            if home <> invalid then
                home.Refresh({ myplex: "connected", servers: true })
            end if

            return true
        end if
    end if

    return false
end function
