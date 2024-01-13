function Restore-WinMgmt {
  [CmdletBinding()]
  param(
    [switch]$Force
  )
  #requires -RunAsAdministrator
  if ((-not (Get-Disk -ErrorAction SilentlyContinue)) -or ($Force -eq $true)) {
    # all commands below must be run in cmd as admin
    $commands = @(
      'sc config winmgmt start= disabled',
      'net stop winmgmt',
      'Winmgmt /salvagerepository %windir%\System32\wbem',
      'Winmgmt /resetrepository %windir%',
      'sc config winmgmt start= auto'
    )

    # Execute each command using cmd.exe /c
    foreach ($command in $commands) {
      Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $command" -NoNewWindow -Wait
    }

    Write-Output 'WinMgmt has been restored.'
  }
  else {
    Write-Warning 'WinMgmt is running correctly And -Force has not been used. Nothing to do.'
  }
  Show-NewAsciiArt
}

<#
.SYNOPSIS
  Short description
.DESCRIPTION
  Long description
.EXAMPLE
  Example of how to use this cmdlet
.EXAMPLE
  Another example of how to use this cmdlet
#>
function Show-NewAsciiArt {
  [CmdletBinding()]
  param(
  )
  # this cmdlet is a ascii art generator
  # from this list of urls that link to a png of the ascii art we will choose one at random and display it in the console:
  $asciiartlist = @'
https://16colo.rs/pack/blocktronics_2022_calendar/tn/00_2022.ans.png
https://16colo.rs/pack/blocktronics_2022_calendar/tn/01_2022.ans.png
https://16colo.rs/pack/blocktronics_2022_calendar/tn/02_2022.ans.png
https://16colo.rs/pack/blocktronics_2022_calendar/tn/03_2022.ans.png
https://16colo.rs/pack/blocktronics_2022_calendar/tn/04_2022.ans.png
https://16colo.rs/pack/blocktronics_2022_calendar/tn/05_2022.ans.png
https://16colo.rs/pack/blocktronics_2022_calendar/tn/06_2022.ans.png
https://16colo.rs/pack/blocktronics_2022_calendar/tn/07_2022.ans.png
https://16colo.rs/pack/blocktronics_2022_calendar/tn/08_2022.ans.png
https://16colo.rs/pack/blocktronics_2022_calendar/tn/09_2022.ans.png
https://16colo.rs/pack/blocktronics_2022_calendar/tn/10_2022.ans.png
https://16colo.rs/pack/blocktronics_2022_calendar/tn/11_2022.ans.png
https://16colo.rs/pack/blocktronics_2022_calendar/tn/12_2022.ans.png
https://16colo.rs/pack/zaal01/tn/Dahomey.ANS.png
https://16colo.rs/pack/zaal01/tn/Evola.asc.png
https://16colo.rs/pack/zaal01/tn/MastUndMitte.ans.png
https://16colo.rs/pack/zaal01/tn/Nagatoro.ans.png
https://16colo.rs/pack/newschool-01/tn/cl-drawing.xb.png
https://16colo.rs/pack/newschool-01/tn/cl-drawing2.xb.png
https://16colo.rs/pack/newschool-01/tn/cl-drawing3.xb.png
https://16colo.rs/pack/newschool-01/tn/er-zoomcall.xb.png
https://16colo.rs/pack/newschool-01/tn/font-1cb.XB.png
https://16colo.rs/pack/newschool-01/tn/font-aa2.xb.png
https://16colo.rs/pack/newschool-01/tn/font-aly.xb.png
https://16colo.rs/pack/newschool-01/tn/font-catkj.xb.png
https://16colo.rs/pack/newschool-01/tn/font-cl.xb.png
https://16colo.rs/pack/newschool-01/tn/font-ghs.xb.png
https://16colo.rs/pack/newschool-01/tn/font-gs.xb.png
https://16colo.rs/pack/newschool-01/tn/font-hf.xb.png
https://16colo.rs/pack/newschool-01/tn/font-hh.xb.png
https://16colo.rs/pack/newschool-01/tn/font-kj.xb.png
https://16colo.rs/pack/newschool-01/tn/font-kjw.xb.png
https://16colo.rs/pack/newschool-01/tn/font-kp.xb.png
https://16colo.rs/pack/newschool-01/tn/font-l1p.xb.png
https://16colo.rs/pack/newschool-01/tn/font-lv.xb.png
https://16colo.rs/pack/newschool-01/tn/font-mf.xb.png
https://16colo.rs/pack/newschool-01/tn/font-ns.xb.png
https://16colo.rs/pack/newschool-01/tn/font-ntby-bwoi.xb.png
https://16colo.rs/pack/newschool-01/tn/font-tkb.XB.png
https://16colo.rs/pack/newschool-01/tn/font-uq.xb.png
https://16colo.rs/pack/newschool-01/tn/font2-1c.xb.png
https://16colo.rs/pack/newschool-01/tn/ghs-s4d-1.xb.png
https://16colo.rs/pack/newschool-01/tn/ghs-s4d-2.xb.png
https://16colo.rs/pack/newschool-01/tn/gs-castle.xb.png
https://16colo.rs/pack/newschool-01/tn/gs-froggo.xb.png
https://16colo.rs/pack/newschool-01/tn/gs-hiding.xb.png
https://16colo.rs/pack/newschool-01/tn/gs-safe-place.xb.png
https://16colo.rs/pack/newschool-01/tn/hf-outside.xb.png
https://16colo.rs/pack/newschool-01/tn/kj-blind.xb.png
https://16colo.rs/pack/newschool-01/tn/l1p-seventemplesofascii.xb.png
https://16colo.rs/pack/newschool-01/tn/lv-cubeeye.xb.png
https://16colo.rs/pack/newschool-01/tn/newschool-01.xb.png
https://16colo.rs/pack/mist1221/tn/ADEL_FAURE-REPUBLIC_KRAMPUS.ANS.png
https://16colo.rs/pack/mist1221/tn/CT-DIE_HARD.ANS.png
https://16colo.rs/pack/mist1221/tn/CT-PIXELS.ANS.png
https://16colo.rs/pack/mist1221/tn/DW-SPRITEMAS.ANS.png
https://16colo.rs/pack/mist1221/tn/KUROGAO-ENJOY_SKIING.JPG
https://16colo.rs/pack/mist1221/tn/KUROGAO-ICE_FISHING.JPG
https://16colo.rs/pack/mist1221/tn/LITTLEBITSPACE-A_DAY_SNOWBOARDING.JPG
https://16colo.rs/pack/mist1221/tn/MIST1221.NFO.ANS.png
https://16colo.rs/pack/mist1221/tn/STARSTEW-LITTLE_MAN_ON_KRAMPUS.JPG
https://16colo.rs/pack/mist1221/tn/US-GREMLINS.ANS.png
https://16colo.rs/pack/mist1221/tn/US-POLAR_BEAR_MAKING_A_SNOWMAN_IN_A_BLIZZARD.ANS.png
https://16colo.rs/pack/mist1221/tn/WA-HAPPY-YULE.ANS.png
https://16colo.rs/pack/mist1021/tn/ADEL_FAURE-VAMPIRE_ZEMMOUR.ANS.png
https://16colo.rs/pack/mist1021/tn/ATONALOSPREY-NOSFERATU.JPG
https://16colo.rs/pack/mist1021/tn/BLIPPYPIXEL-THE_TRAP_DOOR-FLYING_WOTSITFINGY.GIF
https://16colo.rs/pack/mist1021/tn/BNJMNBRGMN-BLACK_GOAT_OF_THE_WOODS.JPG
https://16colo.rs/pack/mist1021/tn/BNJMNBRGMN-COLOUR_OUT_OF_SPACE.JPG
https://16colo.rs/pack/mist1021/tn/BNJMNBRGMN-IN_HIS_HOUSE_AT_R%27LYEH.JPG
https://16colo.rs/pack/mist1021/tn/CHUPPIXEL-PREDATOR.JPG
https://16colo.rs/pack/mist1021/tn/CHUPPIXEL-SQUID_GAME.JPG
https://16colo.rs/pack/mist1021/tn/GODFATHER-THERUINSII.ANS.png
https://16colo.rs/pack/mist1021/tn/HORSENBURGER-AMERICAN_WEREWOLF_IN_LONDON.JPG
https://16colo.rs/pack/mist1021/tn/HORSENBURGER-BRANDON_LEE-AS-THE_CROW.PNG
https://16colo.rs/pack/mist1021/tn/HORSENBURGER-CARRIE.JPG
https://16colo.rs/pack/mist1021/tn/HORSENBURGER-DAY_OF_THE_DEAD-BUB.JPG
https://16colo.rs/pack/mist1021/tn/HORSENBURGER-FRANKENSTEIN.JPG
https://16colo.rs/pack/mist1021/tn/HORSENBURGER-NOSFERATU.JPG
https://16colo.rs/pack/mist1021/tn/HORSENBURGER-PHANTASM.JPG
https://16colo.rs/pack/mist1021/tn/HORSENBURGER-RING.JPG
https://16colo.rs/pack/mist1021/tn/HORSENBURGER-SAW.JPG
https://16colo.rs/pack/mist1021/tn/HORSENBURGER-SCANNERS-MICHAEL_IRONSIDE_AS_DARRYL_REVOK.JPG
https://16colo.rs/pack/mist1021/tn/HORSENBURGER-TEXAS_CHAINSAW_MASSACRE.JPG
https://16colo.rs/pack/mist1021/tn/HORSENBURGER-THE_FLY.JPG
https://16colo.rs/pack/mist1021/tn/KUROGAO-IN_THE_UFO.JPG
https://16colo.rs/pack/mist1021/tn/KUROGAO-NIGHT_TUNNEL.JPG
https://16colo.rs/pack/mist1021/tn/KUROGAO-PLAY_A_PRANK.JPG
https://16colo.rs/pack/mist1021/tn/LITTLEBITSPACE-ALIEN_.PNG
https://16colo.rs/pack/mist1021/tn/LITTLEBITSPACE-AMONGTHEDEAD1.PNG
https://16colo.rs/pack/mist1021/tn/LITTLEBITSPACE-ASCIIPOLAROID_KYBUNNI-GOTH_NEKO.PNG
https://16colo.rs/pack/mist1021/tn/LITTLEBITSPACE-BAPHOMET2.PNG
https://16colo.rs/pack/mist1021/tn/LITTLEBITSPACE-BETRAY.PNG
https://16colo.rs/pack/mist1021/tn/LITTLEBITSPACE-CROW.PNG
https://16colo.rs/pack/mist1021/tn/LITTLEBITSPACE-DEAD_.PNG
https://16colo.rs/pack/mist1021/tn/LITTLEBITSPACE-DIA_DE_LOS_MUERTOS.PNG
https://16colo.rs/pack/mist1021/tn/LITTLEBITSPACE-PSYCHOLOGY_PROXIMITY_SKULLS.PNG
https://16colo.rs/pack/mist1021/tn/LITTLEBITSPACE-SPOOKY.PNG
https://16colo.rs/pack/mist1021/tn/LITTLEBITSPACE-X-RAY.PNG
https://16colo.rs/pack/mist1021/tn/MIST1021.NFO.ANS.png
https://16colo.rs/pack/mist1021/tn/POLYDUCKS-PICOCAD-HAUNTED-HOUSE.GIF
https://16colo.rs/pack/mist1021/tn/POLYDUCKS-PUMPKIN-RENDER.PNG
https://16colo.rs/pack/mist1021/tn/POLYDUCKS-SKELETON-JUMPSCARE.GIF
https://16colo.rs/pack/mist1021/tn/SKONEN_BLADES-FRANKIE.JPG
https://16colo.rs/pack/mist1021/tn/US-DOOM.ANS.png
https://16colo.rs/pack/mist1021/tn/US-PONCHIELLI.ANS.png
https://16colo.rs/pack/mist1021/tn/VERMILEONHART-DEATH_MADE_EASY.PNG
https://16colo.rs/pack/mist1021/tn/VERMILEONHART-HEXED_0X01.PNG
https://16colo.rs/pack/mist1021/tn/VERMILEONHART-HE_WHOM_COULD_NOT_TRULY_BE.PNG
https://16colo.rs/pack/mist1021/tn/VERMILEONHART-LONGING.PNG
https://16colo.rs/pack/mist0921/tn/ATARI_STASH_HOUSE-KEYSTONE_KAPERS_COSMIC_PULSE_WAVE.JPG
https://16colo.rs/pack/mist0921/tn/ATARI_STASH_HOUSE-METAL_GEAR_-_SOLID_SNAKE_ON_THE_MOVE_AGAIN.JPG
https://16colo.rs/pack/mist0921/tn/ATARI_STASH_HOUSE-MISSILE_COMMAND.JPG
https://16colo.rs/pack/mist0921/tn/BHAAL_SPAWN-DOOM-SLAYER.JPG
https://16colo.rs/pack/mist0921/tn/BHAAL_SPAWN-GRIM_FANDANGO.JPG
https://16colo.rs/pack/mist0921/tn/BHAAL_SPAWN-XCOM-APOCALYPSE.JPG
https://16colo.rs/pack/mist0921/tn/DW-DSBBS_ENTRY.ANS.png
https://16colo.rs/pack/mist0921/tn/FARRELL_LEGO-LAST_OF_US_2-ABBY_ANDERSON.JPG
https://16colo.rs/pack/mist0921/tn/FARRELL_LEGO-LAST_OF_US_2-YARA_THE_SERAPHITE.JPG
https://16colo.rs/pack/mist0921/tn/HORSENBURGER-GHOSTS_N_GOBLINS-GAME_OVER.JPG
https://16colo.rs/pack/mist0921/tn/HORSENBURGER-LF-MONKEY_ISLAND-DEMON_PIRATE_LECHUCK.PNG
https://16colo.rs/pack/mist0921/tn/HORSENBURGER-LF-MONKEY_ISLAND-LF-GUYBRUSH_THREEPWOOD-RING.PNG
https://16colo.rs/pack/mist0921/tn/HORSENBURGER-LF-MONKEY_ISLAND-LIGHTHOUSE.JPG
https://16colo.rs/pack/mist0921/tn/HORSENBURGER-LF-MONKEY_ISLAND-MELEE_ISLAND.JPG
https://16colo.rs/pack/mist0921/tn/HORSENBURGER-MASS_EFFECT-GARRUS.JPG
https://16colo.rs/pack/mist0921/tn/HORSENBURGER-MASS_EFFECT-MORDIN_SOLUS.JPG
https://16colo.rs/pack/mist0921/tn/HORSENBURGER-MASS_EFFECT-TALI%27ZORAH.JPG
https://16colo.rs/pack/mist0921/tn/HORSENBURGER-MASS_EFFECT-URDNOT_WREX.JPG
https://16colo.rs/pack/mist0921/tn/HORSENBURGER-SAMANTHA_FOX-POKER-1.JPG
https://16colo.rs/pack/mist0921/tn/HORSENBURGER-SAMANTHA_FOX-POKER-2.JPG
https://16colo.rs/pack/mist0921/tn/ILLARTERATE-ADVANCED_LAWNMOWER_SIMULATOR.PNG
https://16colo.rs/pack/mist0921/tn/ILLARTERATE-TETRIS-SHUTTLE-ASCII-TELETEXT.PNG
https://16colo.rs/pack/mist0921/tn/JELLICA_JAKE-MONSTERS.JPG
https://16colo.rs/pack/mist0921/tn/JELLICA_JAKE-PHANTOM_THIEVES.JPG
https://16colo.rs/pack/mist0921/tn/KUROGAO-STREET_FIGHTER-2.JPG
https://16colo.rs/pack/mist0921/tn/KUROGAO-URBAN_CHAMPION.JPG
https://16colo.rs/pack/mist0921/tn/LDA-EARTHBOUND.ANS.png
https://16colo.rs/pack/mist0921/tn/LITTLEBITSPACE-DINO_RUN.JPG
https://16colo.rs/pack/mist0921/tn/LITTLEBITSPACE-HOW_ARE_YOU_DOING.JPG
https://16colo.rs/pack/mist0921/tn/MAVENMOB_ZELDA-GOGH.PNG
https://16colo.rs/pack/mist0921/tn/MINEDIRU-CENTIPEDE.JPG
https://16colo.rs/pack/mist0921/tn/MINEDIRU-CENTIPEDE_GB.JPG
https://16colo.rs/pack/mist0921/tn/MINEDIRU-CLASH_OF_CLANS-29X29.JPG
https://16colo.rs/pack/mist0921/tn/MINEDIRU-DONKEY_KONG-29X29.JPG
https://16colo.rs/pack/mist0921/tn/MINEDIRU-MARIO_SHINING.JPG
https://16colo.rs/pack/mist0921/tn/MINEDIRU-OCTOPUS-29X29.JPG
https://16colo.rs/pack/mist0921/tn/PIXEL_ART_FOR_THE_HEART-CHARBOK.PNG
https://16colo.rs/pack/mist0921/tn/PIXEL_ART_FOR_THE_HEART-CLOYSTER.PNG
https://16colo.rs/pack/mist0921/tn/PIXEL_ART_FOR_THE_HEART-FF-BOMB.PNG
https://16colo.rs/pack/mist0921/tn/PIXEL_ART_FOR_THE_HEART-MAJORA%27S_MASK.PNG
https://16colo.rs/pack/mist0921/tn/PIXEL_ART_FOR_THE_HEART-SABLEYE.PNG
https://16colo.rs/pack/mist0921/tn/PIXEL_ART_FOR_THE_HEART-SAMUS.PNG
https://16colo.rs/pack/mist0921/tn/PIXEL_ART_FOR_THE_HEART-SHADOW_OF_THE_COLOSSUS.JPG
https://16colo.rs/pack/mist0921/tn/POLYDUCKS-PICOCAD-KING-BOO.GIF
https://16colo.rs/pack/mist0921/tn/RAPID99-EEVEE.PNG
https://16colo.rs/pack/mist0921/tn/RAPID99-JET_GRIND_RADIO-BEAT.PNG
https://16colo.rs/pack/mist0921/tn/RAPID99-MEGA_MAN.PNG
https://16colo.rs/pack/mist0921/tn/RAPID99-MEWTWO_MEGA_EVOLUTION_Y.PNG
https://16colo.rs/pack/mist0921/tn/RAPID99-SONIC_LEGS1.PNG
https://16colo.rs/pack/mist0921/tn/RAPID99-TY_THE_TASMANIAN_TIGER.PNG
https://16colo.rs/pack/mist0921/tn/SONTOLHEAD_FIDYAN-RDR2-ARTHUR_MORGAN.PNG
https://16colo.rs/pack/mist0921/tn/SONTOLHEAD_FIDYAN-RDR2-BILL_WILLIAMSON.PNG
https://16colo.rs/pack/mist0921/tn/SONTOLHEAD_FIDYAN-RDR2-DUTCH_VAN_DER_LINDE.PNG
https://16colo.rs/pack/mist0921/tn/SONTOLHEAD_FIDYAN-RDR2-HOSEA_MATTHEWS.PNG
https://16colo.rs/pack/mist0921/tn/SONTOLHEAD_FIDYAN-RDR2-JAVIER_ESCUELLA.PNG
https://16colo.rs/pack/mist0921/tn/US-OLD_SNAKE.ANS.png
https://16colo.rs/pack/mist0921/tn/US-TETRIS.ANS.png
https://16colo.rs/pack/mist0921/tn/US-ULTRAKILLV1.ANS.png
https://16colo.rs/pack/mist0921/tn/ZYLONE-DIABLO_3.ANS.png
https://16colo.rs/pack/mist0721/tn/ATONALOSPREY-ANTHONY_FAUCI.JPG
https://16colo.rs/pack/mist0721/tn/ATONALOSPREY-DREAMS.JPG
https://16colo.rs/pack/mist0721/tn/ATONALOSPREY-MOONRISE.JPG
https://16colo.rs/pack/mist0721/tn/ATONALOSPREY-PERSEVERANCE.JPG
https://16colo.rs/pack/mist0721/tn/ATONALOSPREY-TOKYO_AT_NIGHT.JPG
https://16colo.rs/pack/mist0721/tn/BLIPPYPIXEL-OUT_WITH_THE_OLD_IN_THE_THE_UNAFFORDABLE.PNG
'@


  function Show-TerminalPicture {
    <#
  .SYNOPSIS
      Displays a PNG image or image from a URL in the Windows Terminal.
  
  .DESCRIPTION
      This function renders a PNG image or an image from a URL directly in the Windows Terminal using ANSI escape sequences.
  
  .PARAMETER Path
      The path to the PNG image file or a URL ending with '.png'.
  
  .EXAMPLE
      Show-TerminalPicture -Path "C:\path\to\image.png"
  
  .EXAMPLE
      Show-TerminalPicture -Path "http://example.com/image.png"
  
  .NOTES
      Requires PowerShell to have access to System.Drawing assembly.
  
  .LINK
      https://docs.microsoft.com/en-us/powershell/scripting/developer/cmdlet/cmdlet-overview
  #>
  
    [CmdletBinding()]
    param(
      [Parameter(Mandatory)]
      [String]$Path
    )
  
    begin {
      [System.Reflection.Assembly]::LoadWithPartialName('System.Drawing') | Out-Null
      $escape = [Char]0x1B
    }

    process {
      function GetTerminalSize() {
        return [PSCustomObject]@{
          Width  = [Console]::WindowWidth
          Height = [Console]::WindowHeight
        }
      }

      function ResizeImage([System.Drawing.Image]$Image) {
        $terminalSize = GetTerminalSize
        $maxHeight = [Math]::Round($terminalSize.Height * 0.7) * 2 # Multiply by 2 because each console line is two pixels tall in image terms
        $ratio = [Math]::Min($maxHeight / $Image.Height, 1)
        $newWidth = [Math]::Round($Image.Width * $ratio)
        $newHeight = [Math]::Round($Image.Height * $ratio)

        $resized = New-Object System.Drawing.Bitmap($newWidth, $newHeight)
        $graphics = [System.Drawing.Graphics]::FromImage($resized)
        $graphics.DrawImage($Image, 0, 0, $newWidth, $newHeight)
        $graphics.Dispose()

        return $resized
      }
      function LoadImageFromPath($Path) {
        $imageStream = [System.IO.File]::OpenRead($Path)
        try {
          [System.Drawing.Image]::FromStream($imageStream, $false, $false)
        }
        finally {
          $imageStream.Dispose()
        }
      }
  
      function LoadImageFromUrl($Url) {
        $webClient = New-Object System.Net.WebClient
        try {
          $imageData = $webClient.DownloadData($Url)
          $imageStream = New-Object System.IO.MemoryStream($imageData, $false)
          try {
            [System.Drawing.Image]::FromStream($imageStream)
          }
          finally {
            $imageStream.Dispose()
          }
        }
        finally {
          $webClient.Dispose()
        }
      }
  
      function RenderImage([System.Drawing.Image]$Image) {
        [Console]::CursorVisible = $false
        for ($y = 0; $y -lt $Image.Height; $y++) {
          $pixelStrings = for ($x = 0; $x -lt $Image.Width; $x++) {
            $pixel = $Image.GetPixel($x, $y)
            "$escape[48;2;$($pixel.R);$($pixel.G);$($pixel.B)m "
          }
          [String]::Join('', $pixelStrings + "$escape[0m`n")
        }
        [Console]::CursorVisible = $true
      }
  
      if ($Path -match '^https?://') {
        $img = LoadImageFromUrl $Path
      }
      else {
        if (-not (Test-Path $Path -PathType Leaf)) {
          Write-Error "File not found: $Path"
          return
        }
        $img = LoadImageFromPath $Path
      }

      try {
        $resizedImg = ResizeImage -Image $img
        RenderImage -Image $resizedImg
      }
      finally {
        $img.Dispose()
        $resizedImg.Dispose()
      }
    }
  }
  $images = $asciiartlist -split '[\r\n]+'
  # select a random image from the array
  $randomImage = $images | Get-Random

  # show the image
  Show-TerminalPicture -Path $randomImage

}

