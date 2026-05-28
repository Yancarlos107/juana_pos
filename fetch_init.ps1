$ErrorActionPreference = "Stop"

try {
    $loginBody = @{
        phone_number = "3010000051"
        password = "11223344"
        device_name = "postman"
    } | ConvertTo-Json

    $loginResponse = Invoke-RestMethod -Uri "http://35.209.80.61:8089/api/cashier-login" -Method Post -Body $loginBody -ContentType "application/json" -Headers @{"Accept"="application/json"}
    
    $token = $loginResponse.data.token
    if (-not $token) { $token = $loginResponse.token }

    $headers = @{
        "Accept" = "application/json"
        "Authorization" = "Bearer $token"
    }
    
    $scheduleBody = @{
        pos_location_id = 6
    } | ConvertTo-Json

    $response = Invoke-RestMethod -Uri "http://35.209.80.61:8089/api/pos-schedules/my-today" -Method Put -Body $scheduleBody -ContentType "application/json" -Headers $headers
    $response | ConvertTo-Json -Depth 6 > "e:\PROYECTOS\DASHFLEET\sistema-pos\schedule_response.json"
    Write-Host "Schedule updated."

} catch {
    Write-Host "Error: $($_.Exception.Message)"
    if ($_.Exception.Response) {
        $stream = $_.Exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $errBody = $reader.ReadToEnd()
        Write-Host "Body: $errBody"
    }
}
