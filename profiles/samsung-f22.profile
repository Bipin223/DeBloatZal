# ============================================================================
#  Samsung Galaxy F22  (SM-F221 / a22 family) - One UI 3.x - 5.x, Android 11-13
# ----------------------------------------------------------------------------
#  Sections:
#    [match]    regex matched against the phone codename and model
#    [core]     safe bloat: ads, telemetry, Bixby/Game preloads, Office, social apps
#    [optional] apps you may actually use - only removed with "all" tier
#    [protect]  extra packages this tool must never touch
#  One package per line. Lines starting with # are ignored.
# ============================================================================

[match]
# Galaxy F22 4G (SM-F221) and F22 5G (SM-E225F, codename a22x/e225)
a22
F221
E225
a22x
e225

[core]
# Samsung Free / left-most home panel (disappears when removed)
com.samsung.android.app.spage
# Bixby stack (F22 has no Bixby button, but the services run in background)
com.samsung.android.bixby.agent
com.samsung.android.bixby.wakeup
com.samsung.android.app.settings.bixby
com.samsung.android.bixbyvision.framework
com.samsung.android.visionintelligence
# Tips, Members, Reminder, Watch stub
com.samsung.android.app.tips
com.samsung.android.voc
com.samsung.android.mateagent
com.samsung.android.app.reminder
com.samsung.android.app.watchmanagerstub
# Game Launcher / Game Tools / Game Optimizing Service
com.samsung.android.game.gamehome
com.samsung.android.game.gametools
com.samsung.android.game.gos
# AR Zone, Samsung Social, Smart Switch agent
com.samsung.android.arzone
com.samsung.android.app.social
com.samsung.android.smartswitchassistant
# Telemetry
com.samsung.android.dqagent
com.samsung.android.knox.analytics.uploader
# Chrome OS customisations (not Chrome itself)
com.sec.android.app.chromecustomizations
# Microsoft preloads
com.microsoft.appmanager
com.microsoft.office.outlook
com.microsoft.office.word
com.microsoft.office.excel
com.microsoft.office.powerpoint
# Social / streaming preloads
com.linkedin.android
com.netflix.mediaclient
com.spotify.music
com.amazon.appmanager
com.amazon.mShop.android.shopping
# Added after cross-check with the UAD-NG database (all rated "Recommended")
com.samsung.android.app.omcagent
com.samsung.android.bixby.agent.dummy
com.samsung.android.bixby.es.globalaction
com.samsung.android.bixby.plmsync
com.samsung.android.bixby.service
com.samsung.android.bixby.voiceinput

[optional]
# Facebook is optional so Select recommended never touches it.
com.facebook.katana
com.facebook.appmanager
com.facebook.services
com.facebook.system
# Google apps (often duplicated by Samsung apps)
com.google.android.youtube
com.google.android.apps.youtube.music
com.google.android.apps.tachyon
com.google.android.apps.photos
com.google.android.apps.maps
com.google.android.gm
com.google.android.apps.docs
com.google.android.apps.wellbeing
com.google.android.videos
com.google.android.apps.subscriptions.red
com.android.chrome
# Samsung apps you may or may not use
com.sec.android.app.sbrowser
com.samsung.android.app.notes
com.samsung.android.calendar
com.samsung.android.email.provider
# Removing the default SMS app leaves the phone without SMS until you
# install another one (e.g. Google Messages) first.
com.samsung.android.messaging
# Edge panels
com.samsung.android.app.cocktailbarservice
com.samsung.android.app.appsedge
com.samsung.android.app.taskedge
com.samsung.android.app.clipboardedge
com.samsung.android.app.sbrowseredge
# AR Emoji / AOD / Cloud / TTS
com.samsung.android.aremoji
com.samsung.android.emoji
com.samsung.android.aremojieditor
com.samsung.android.app.aodservice
com.samsung.android.scloud
com.samsung.SMT
# Optional extras from the UAD-NG cross-check
com.samsung.android.app.watchmanager
com.samsung.android.app.camera.sticker.facear.preload
com.samsung.android.app.camera.sticker.facearavatar.preload
com.samsung.android.app.camera.sticker.stamp.preload
com.samsung.android.app.memo
com.samsung.android.app.pinboard
com.samsung.android.app.simplesharing
com.samsung.android.app.sketchbook
com.samsung.android.app.parentalcare
com.samsung.android.app.vrsetupwizardstub
com.samsung.android.app.earphonetypec
com.samsung.android.app.ledcoverdream
com.samsung.android.app.mirrorlink
com.samsung.android.app.filterinstaller
com.samsung.android.allshare.service.mediashare
com.samsung.android.beaconmanager
com.samsung.android.easysetup
com.samsung.android.fast
com.samsung.android.coreapps
com.samsung.android.da.daagent
com.samsung.android.deviceidservice
com.samsung.android.dsms
com.samsung.android.coldwalletservice
com.samsung.android.digitalkey
com.samsung.android.drivelink.stub
com.samsung.android.ardrawing

[protect]
com.sec.android.app.launcher
com.samsung.android.honeyboard
com.android.systemui
com.android.settings
com.samsung.android.dialer
com.samsung.android.incallui
com.samsung.android.app.telephonyui
com.samsung.android.app.contacts
com.sec.android.app.camera
com.sec.android.app.clockpackage
com.android.phone
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
com.samsung.android.MtpApplication
com.android.location.fused

[note]
Keep Samsung Account, Galaxy Store and Knox core if you use Secure Folder,
Find My Mobile, or Samsung backups. This profile does not touch them.
