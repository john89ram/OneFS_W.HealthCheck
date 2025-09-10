# Ensure STA for WinForms
try {
  if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = (Get-Process -Id $PID).Path
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $psi.UseShellExecute = $false
    [System.Diagnostics.Process]::Start($psi) | Out-Null
    exit
  }
} catch {}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Show-SSHLoginDialog {
  param(
    [string]$DefaultHost = '',
    [string]$DefaultUser = '',
    [string]$DefaultZone = 'System',
    [int]$DefaultPort = 22
  )

  $form = New-Object System.Windows.Forms.Form
  $form.Text="PowerScale SSH Login"; $form.StartPosition='CenterScreen'
  $form.Size=New-Object System.Drawing.Size(440,320); $form.Topmost=$true
  $font=New-Object System.Drawing.Font('Segoe UI',10)

  function L($t,$x,$y){$l=New-Object System.Windows.Forms.Label;$l.Text=$t;$l.Left=$x;$l.Top=$y;$l.AutoSize=$true;$l.Font=$font;$l}
  function T($x,$y,$w){$t=New-Object System.Windows.Forms.TextBox;$t.Left=$x;$t.Top=$y;$t.Width=$w;$t.Font=$font;$t}

  $lblH=L "SSH IP / Hostname:" 20 20; $txtH=T 20 45 380; $txtH.Text=$DefaultHost
  $lblU=L "Username:" 20 80; $txtU=T 20 105 180; $txtU.Text=$DefaultUser
  $lblP=L "Password:" 220 80; $txtP=T 220 105 180; $txtP.UseSystemPasswordChar=$true
  $lblPort=L "Port:" 20 140; $txtPort=T 20 165 80; $txtPort.Text="$DefaultPort"
  $lblZ=L "Access Zone:" 120 140; $txtZ=T 120 165 280; $txtZ.Text=$DefaultZone

  $ok=New-Object System.Windows.Forms.Button; $ok.Text="Connect"; $ok.Left=220; $ok.Top=215; $ok.Width=90; $ok.Font=$font
  $cancel=New-Object System.Windows.Forms.Button; $cancel.Text="Cancel"; $cancel.Left=320; $cancel.Top=215; $cancel.Width=80; $cancel.Font=$font
  $err=L "" 20 195; $err.ForeColor=[System.Drawing.Color]::FromArgb(200,40,40); $err.Width=380

  $ok.Add_Click({
    $err.Text=""
    if([string]::IsNullOrWhiteSpace($txtH.Text) -or [string]::IsNullOrWhiteSpace($txtU.Text) -or [string]::IsNullOrWhiteSpace($txtP.Text)){
      $err.Text="Please fill Host, Username, and Password."; return
    }
    if(-not [int]::TryParse($txtPort.Text,[ref]0)){ $err.Text="Port must be a number."; return }
    $form.DialogResult=[System.Windows.Forms.DialogResult]::OK; $form.Close()
  })
  $cancel.Add_Click({ $form.DialogResult=[System.Windows.Forms.DialogResult]::Cancel; $form.Close() })

  $form.Controls.AddRange(@($lblH,$txtH,$lblU,$txtU,$lblP,$txtP,$lblPort,$txtPort,$lblZ,$txtZ,$ok,$cancel,$err))
  $null=$form.ShowDialog()
  if($form.DialogResult -ne [System.Windows.Forms.DialogResult]::OK){ return $null }

  $sec=ConvertTo-SecureString $txtP.Text -AsPlainText -Force
  $cred=New-Object System.Management.Automation.PSCredential($txtU.Text,$sec)

  [pscustomobject]@{ Host=$txtH.Text.Trim(); Port=[int]$txtPort.Text; Zone=$txtZ.Text.Trim(); Credential=$cred }
}

Export-ModuleMember -Function Show-SSHLoginDialog
