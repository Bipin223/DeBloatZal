# ============================================================================
#  Redmi 9C  (cattail / angelican) - MIUI 12, Android 10
# ----------------------------------------------------------------------------
#  Sections:
#    [match]    regex matched against the phone codename and model
#    [core]     safe bloat: ads, telemetry, preinstalled Facebook/Netflix/etc.
#    [optional] apps you may actually use - only removed with "all" tier
#    [protect]  extra packages this tool must never touch
#  One package per line. Lines starting with # are ignored.
# ============================================================================

[match]
cattail
angelican
M2006C3

[core]
com.miui.analytics
com.miui.msa.global
com.miui.systemAdSolution
com.xiaomi.mipicks
com.miui.hybrid
com.miui.hybrid.accessory
com.mi.globalbrowser
com.miui.videoplayer
com.miui.player
com.miui.fm
com.miui.bugreport
com.miui.miservice
com.miui.android.fashiongallery
com.miui.cleaner
com.amazon.mShop.android.shopping
com.amazon.appmanager
com.netflix.mediaclient
com.spotify.music
com.google.android.videos
com.google.android.apps.subscriptions.red
com.google.android.apps.tachyon
# Added after cross-check with the UAD-NG database (all rated "Recommended")
com.mi.global.bbs
com.mi.global.shop
com.miui.klo.bugreport
com.miui.misightservice
com.miui.spock
com.miui.wmsvc
com.miui.cleanmaster
com.miui.cit
com.miui.video
com.miui.tv.analytics
com.miui.uireporter
com.miui.fmservice
com.xiaomi.android.tvsetup.partnercustomizer

[optional]
# Facebook is optional so Select recommended never touches it.
com.facebook.katana
com.facebook.appmanager
com.facebook.services
com.facebook.system
com.google.android.youtube
com.google.android.apps.youtube.music
com.google.android.apps.photos
com.google.android.apps.maps
com.google.android.gm
com.google.android.apps.docs
com.google.android.apps.wellbeing
com.google.android.apps.nbu.files
com.android.chrome
com.miui.gallery
com.miui.calculator
com.miui.notes
com.miui.compass
com.miui.weather2
com.miui.screenrecorder
com.miui.personalassistant
com.miui.cloudservice
com.miui.cloudbackup
com.miui.huanji
com.miui.backup
com.miui.voiceassist
com.xiaomi.midrop
# Game/performance service. Removing frees resources but can disable some
# MIUI Game Turbo features.
com.xiaomi.joyose
# Optional extras from the UAD-NG cross-check
com.miui.antispam
com.miui.extraphoto
com.miui.userguide
com.miui.yellowpage
com.miui.translationservice
com.miui.translation.kingsoft
com.miui.translation.xmcloud
com.miui.translation.youdao
com.miui.phrase
com.miui.qr
com.miui.touchassistant
com.miui.thirdappassistant
com.miui.vipservice
com.miui.voicetrigger
com.miui.contentextension
com.miui.accessibility
com.miui.miwallpaper.earth
com.miui.miwallpaper.mars
com.xiaomi.mirecycle
com.xiaomi.calendar
com.xiaomi.gamecenter
com.xiaomi.glgm
com.xiaomi.mirror
com.xiaomi.scanner

[protect]
com.miui.home
com.miui.securitycenter
com.miui.securityadd
com.miui.packageinstaller
com.miui.powerkeeper
com.miui.daemon
com.miui.contentcatcher
com.miui.wallpaper
com.miui.miwallpaper
com.lbe.security.miui
com.miui.face
com.android.systemui
com.android.settings
com.android.phone
com.android.contacts
com.android.incallui
com.android.mms
com.android.server.telecom
com.android.providers.telephony
com.android.providers.settings
com.android.providers.contacts
com.android.packageinstaller
com.google.android.packageinstaller
com.google.android.gms
com.google.android.gsf
com.google.android.webview
com.android.vending
com.android.location.fused

[note]
MIUI may block pm uninstall on some system apps until
"USB debugging (Security settings)" is enabled in Developer options.
If uninstall fails, use -Mode disable.
