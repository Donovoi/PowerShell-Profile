Get-UIAWindow -ProcessName safari,chrome,firefox,iexplore,opera | ForEach-Object { $_.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Normal); $_ | Invoke-UIAWindowTransformResize -TransformResizeWidth 500 -TransformResizeHeight 500 };

