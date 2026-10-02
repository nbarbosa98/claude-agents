$DESIRED = @(
    @{ Kind = 'Registry'; Path = 'HKLM:\SOFTWARE\ExampleVendor\ExampleApp'; Name = 'TelemetryLevel'; Type = 'DWord'; Value = 0 },
    @{ Kind = 'Service'; Name = 'ExampleSvc'; StartType = 'Disabled'; StopIfRunning = $false; AbsentIsCompliant = $true }
)
