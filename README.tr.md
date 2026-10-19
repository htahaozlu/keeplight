<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/logo-dark.png">
    <img src="docs/images/logo-light.png" alt="Keeplight" width="460">
  </picture>
</p>

<p align="center">
  <a href="README.md">English</a> | Türkçe
</p>

<p align="center">
  <strong>Mac'inizdeki her ekran için parlaklık ve çözünürlük; her değişiklikten de bir dönüş yolu.</strong>
</p>

<p align="center">
  Keeplight, masanızdaki ekranlar için küçük bir menü çubuğu uygulaması ve komut satırı aracı. Tek bir
  kaydırıcı harici monitörün parlaklığını DDC/CI ile ayarlar; gece monitörün kendi en düşük ayarı bile
  fazla parlak geldiğinde onun da altına iner. HiDPI modları dahil istediğiniz çözünürlüğü seçin.
  Onaylamadığınız bir değişiklik 15 saniye sonra kendiliğinden geri alınır; kararan bir ekran uzun
  sürmez. Ağ yok, telemetri yok; dayandığı belgelenmemiş macOS arayüzleri saklanmaz, uygulamada
  listelenir.
</p>

<p align="center">
  <a href="https://github.com/htahaozlu/keeplight/releases/latest/download/Keeplight.dmg">
    <img src="docs/images/download-macos.svg" alt="Keeplight'ı macOS için indir" width="300">
  </a>
</p>

<p align="center">
  <strong>Homebrew mu?</strong> <code>brew install --cask htahaozlu/keeplight/keeplight</code>
</p>

<p align="center">
  <a href="https://github.com/htahaozlu/keeplight/releases/latest"><img alt="Son sürüm" src="https://img.shields.io/github/v/release/htahaozlu/keeplight?style=flat-square&label=release&color=111113"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111113?style=flat-square">
  <img alt="Apple Silicon ve Intel" src="https://img.shields.io/badge/arch-Apple%20Silicon%20%7C%20Intel-111113?style=flat-square">
  <img alt="Notarize" src="https://img.shields.io/badge/signed-notarized%20by%20Apple-111113?style=flat-square">
  <a href="LICENSE"><img alt="Lisans: MIT" src="https://img.shields.io/badge/license-MIT-111113?style=flat-square"></a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/hero-dark.svg">
    <img src="docs/images/hero-light.svg" alt="Keeplight paneli menü çubuğundan açılır; parlaklık kaydırıcısı 72'den 0'a çekilir ve monitör kendi en düşük ayarının da altına kararır. Ardından 3008 × 1692 seçilir: Keep kartının on beş kırmızı noktası birer birer söner, kimse Keep'e basmaz ve çözünürlük geri döner." width="100%">
  </picture>
</p>

## Neden Keeplight

- **Monitörün inebildiğinden daha karanlık.** Çoğu monitörün en düşük arka ışığı, bir Mac ekranının en
  düşük kademesinden çok daha parlaktır. Keeplight'ın kaydırıcısı yaklaşık 19'a kadar monitörün kendi
  aralığını kullanır; bunun altında arka ışık en düşükte kalır ve Keeplight görüntüyü ekranın gama
  tablosuyla kendisi karartır, 0'da bir Mac ekranı gibi tam siyaha kadar. Keeplight kapanınca macOS
  tabloyu eski haline getirir.
- **Riskli her değişiklik Keep'i bekler.** Yeni bir çözünürlük, ana ekran, yansıtma ya da bağlantı kesme,
  her ekranda on beş kırmızı noktalı bir kart açar. <kbd>Return</kbd> değişikliği tutar; <kbd>Esc</kbd>
  ya da 15 sn (isterseniz 30 sn) hiçbir şey yapmamak eski düzeni geri getirir. Mac uyursa ya da ekran
  önce ayrılırsa da geri alınır; Keeplight kapanır ya da çökerse bekleyen değişiklik en geç yeniden
  açılışta geri alınır. Görüntü tamamen mi gitti? <kbd>⌃⌥⌘R</kbd>'yi basılı tutun.
- **Tek, sakin bir panel.** Her ekran, Control Center dilinde bir kaydırıcı ve çözünürlüğüyle bir kutu.
  Dahili ve Apple ekranları macOS üzerinden, harici monitörler DDC/CI ile. Dock simgesi yok, ses yok;
  uygulamadaki tek kırmızı, geri sayım noktaları.
- **Nasıl yaptığı konusunda dürüst.** Keeplight 13 belgelenmemiş macOS fonksiyonu çağırır (ekran modları,
  Apple parlaklığı, ekran adları, DDC/CI). Hepsi çalışma anında aranır, Settings › About'ta ve
  `keeplight interfaces` ile listelenir; bir macOS güncellemesi birini kaldırırsa yalnız ona bağlı özellik
  kapanır. Uygulamada hiç ağ kodu yok; biri eklenirse build başarısız olur.
- **Erişilebilir.** Panel ve kart kontrollerinin VoiceOver etiketleri var, Keep kartı kalan süreyi söyler;
  Hareketi Azalt, Saydamlığı Azalt ve Kontrastı Artır desteklenir.

## Özellikler

| | |
|---|---|
| **Parlaklık** | Dahili ve Apple ekranları macOS üzerinden, harici monitörler DDC/CI ile (Apple silicon). Kaydırıcıyı sürükleyin ya da klavyenin parlaklık tuşlarını açın: imlecin altındaki monitörü değiştirir ve küçük bir seviye kartı gösterir (macOS'taki gibi çeyrek adımlar için <kbd>⌥</kbd> basılı tutun). Dahili ve Apple ekranlarında macOS'un kendi tuşları ve göstergesi kalır. |
| **En düşüğün altı** | DDC monitörde kaydırıcının alt kısmı, yani 16 tuş kademesinin en alttaki 3'ü, arka ışığı en düşükte tutup görüntüyü daha da karartır. CLI monitörün kendi 0–100 aralığında kalır. |
| **Çözünürlük** | En çok altı önerilen boyut tek tık uzakta; `Show All…` HiDPI dahil kullanılabilir her modu yenileme hızına göre gruplar (`keeplight modes --all` ham listeyi bile gösterir). `Soft`, o panelde bulanık görünecek boyutu işaretler. |
| **Tut ya da geri dönsün** | Çözünürlük, ana ekran, yansıtma ve bağlantı kesme Keep kartında bekler: <kbd>Return</kbd> tutar, <kbd>Esc</kbd> ya da süre (15 ya da 30 sn) geri alır. |
| **Kurtarma** | <kbd>⌃⌥⌘R</kbd>'yi basılı tutun: Keeplight bekleyeni geri alır, kestiği ekranları yeniden bağlar, başlattığı yansıtmaları durdurur ve en son tuttuğunuz düzeni geri yükler. Açılırken <kbd>⇧</kbd>'yi basılı tutarsanız hiçbir şey uygulamayan güvenli başlangıç yapar. |
| **Düzen** | Bir ekranı ana ekran yapın, yansıtın, yansıtmayı durdurun, oturumu kapatana kadar bağlantısını kesin ya da hangi ekranın hangisi olduğunu görmek için adına tıklayın. |
| **Geri alma ve geçmiş** | Panelde <kbd>⌘Z</kbd> ya da bildirimin `Undo` düğmesi. Uygulamadan ve CLI'dan gelen her değişiklik tek bir günlüğe yazılır. |
| **Uykudan sonra** | Uyanınca parlaklık geri ayarlanır (varsayılan açık); bildirim ve `Undo` ile. |
| **Teşhis** | `No brightness control ⓘ` nedenini tek satırda söyler; Settings › Displays'te `Check Again` ve `Copy Report` var; `keeplight doctor` hata bildirimi için her adımı derecelendirir. |

<table>
  <tr>
    <td width="50%" valign="top">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/app/panel-1-display-dark.png">
        <img src="docs/images/app/panel-1-display-light.png" alt="Tek harici monitörlü panel: adı, 72'deki kapsül parlaklık kaydırıcısı ve 3840 × 2160 çözünürlük düğmesi">
      </picture>
      <p align="center"><sub>Tek monitör: parlaklık ve çözünürlük.</sub></p>
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/app/keep-card-dark.gif">
        <img src="docs/images/app/keep-card-light.gif" alt="Keep kartı Keep 3008 × 1692? diye sorar; on beş kırmızı nokta sağdan söner, sonra Reverted yazar">
      </picture>
      <p align="center"><sub>Keep kartı, 4× hız: kimse Keep'e basmadı, geri döndü.</sub></p>
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/app/osd-dark.png">
        <img src="docs/images/app/osd-light.png" alt="Parlaklık tuşu seviye kartı: bir güneş ve dörtte üçü dolu bir kapsül">
      </picture>
      <p align="center"><sub>DDC monitörde parlaklık tuşları.</sub></p>
    </td>
    <td width="50%" valign="top">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/images/app/panel-3-displays-dark.png">
        <img src="docs/images/app/panel-3-displays-light.png" alt="Üç ekranlı panel: dahili ekran, Main işaretli bir DELL monitör ve No brightness control yazan bir LG monitör">
      </picture>
      <p align="center"><sub>Üç ekran; biri parlaklık kontrolü olmadan.</sub></p>
    </td>
  </tr>
</table>

<sub>Buradaki her ekran görüntüsü, uygulamanın gerçek görünümlerinin taklit ekranlarla ekran dışında
alınmış bir render'ı (`scripts/render.sh`); panel, Saydamlığı Azalt biçimiyle gösteriliyor.</sub>

## Kurulum

### Doğrudan indirme (DMG)

1. Son sürümden [**Keeplight.dmg**](https://github.com/htahaozlu/keeplight/releases/latest/download/Keeplight.dmg)
   dosyasını indirin (universal: Apple silicon ve Intel; macOS 14 Sonoma ya da üstü).
2. Açın ve **Keeplight**'ı **Uygulamalar**'a sürükleyin.
3. Başlatın. Sürüm build'leri Developer ID ile imzalı ve Apple tarafından notarize edilmiştir; Keeplight
   uyarı vermeden açılır. Her sürüm DMG'nin SHA-256'sını yanında listeler.

Keeplight menü çubuğunda yaşar: simgesine (içinde ışık yükselen bir ekran) tıklayın ya da
<kbd>⌃⌥⌘D</kbd>'ye basın. Komut satırı aracı uygulamanın içinde gelir; `PATH`'e eklemek için:

```sh
sudo mkdir -p /usr/local/bin
sudo ln -sf /Applications/Keeplight.app/Contents/Helpers/keeplight /usr/local/bin/keeplight
```

### Homebrew

```sh
brew install --cask htahaozlu/keeplight/keeplight
```

`brew` ilk seferde `htahaozlu/homebrew-keeplight`'ı ekler ve `keeplight` komutunu bağlar. Güncelleme:
`brew upgrade --cask htahaozlu/keeplight/keeplight`; `brew uninstall --cask --zap keeplight` Keeplight'ın
kayıtlı durumunu ve tercihlerini de siler.

### Kaynaktan build

Gerekenler: macOS 14+, Xcode 16 ya da üstü (Swift 6). Üçüncü taraf bağımlılık yok.

```sh
git clone https://github.com/htahaozlu/keeplight.git && cd keeplight
swift build && swift test
scripts/bundle-app.sh          # → dist/Keeplight.app ve dist/keeplight
open dist/Keeplight.app
```

Yerel build **ad-hoc imzalıdır**: onu derleyen Mac'te sorunsuz çalışır ama başkalarına verilecek bir
build değildir. macOS Erişilebilirlik iznini imzaya bağlar ve ad-hoc imza her build'de değişir; yeniden
derledikten sonra parlaklık tuşları izni yeniden ister (System Settings › Privacy & Security ›
Accessibility'deki eski Keeplight kaydını kaldırın, sonra tuşları kapatıp açın).

### İlk açılış

Kısa bir pencere ekranlarınızı, bir değişikliğin Keep'i nasıl beklediğini ve bir DDC monitör bağlıysa
parlaklık tuşlarını tek izin isteğiyle (`Allow…` ya da `Not Now`) ve `Open at login`'i gösterir. Bir kez
açılır; içindeki her şey Settings'te de var.

<table>
  <tr>
    <td width="33%"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/app/onboarding-1-dark.png"><img src="docs/images/app/onboarding-1-light.png" alt="Hoş geldiniz: ekranlarınız ana hatlarıyla, ışıkları yanarak"></picture></td>
    <td width="33%"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/app/onboarding-2-dark.png"><img src="docs/images/app/onboarding-2-light.png" alt="Değişiklikler Keep'i bekler: noktalarıyla bir Keep kartı"></picture></td>
    <td width="33%"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/app/onboarding-3-dark.png"><img src="docs/images/app/onboarding-3-light.png" alt="Parlaklık tuşları: tek Erişilebilirlik isteği, Not Now ya da Allow"></picture></td>
  </tr>
</table>

### Ayarlar

`General`'da girişte açılma, menü çubuğu simgesi, geri alma süresi, uyanınca parlaklık ve parlaklık
tuşları; `Displays`'te her ekranın adı, parlaklığının nasıl çalıştığı (`DDC/CI`, `macOS` ya da neden
çalışmadığı) ve rapor kopyalama; `About`'ta uygulamanın şu an ne yaptığının ölçümü.

<table>
  <tr>
    <td width="33%"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/app/settings-general-dark.png"><img src="docs/images/app/settings-general-light.png" alt="Settings › General"></picture></td>
    <td width="33%"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/app/settings-displays-dark.png"><img src="docs/images/app/settings-displays-light.png" alt="Settings › Displays"></picture></td>
    <td width="33%"><picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/app/settings-about-dark.png"><img src="docs/images/app/settings-about-light.png" alt="Settings › About: 0 bağlantı, Erişilebilirlik kullanılmıyor, 13 özel API'nin 13'ü bulundu"></picture></td>
  </tr>
</table>

## İzinler ve gizlilik

- **Tek izin, o da isterseniz.** Erişilebilirlik (Accessibility) yalnız parlaklık tuşları için gerekir ve
  macOS onu yalnız tuşları açtığınızda sorar, açılışta kendiliğinden asla. DDC/CI dahil geri kalan hiçbir
  şey izin istemez. İzin giderse Settings bunu söyler ve `Allow in System Settings…` önerir.
- **Ağ yok.** Keeplight'ta ağ kodu yok: iki binary'den biri soket, URL yükleme ya da Network.framework
  sembolü içe aktarırsa ya da bir ağ framework'üne bağlanırsa `scripts/audit-network.sh` build'i durdurur.
  Güncelleme denetimi yok. Settings › About, sekmeyi açtığınızda uygulamanın açık internet soketlerini
  sayar (`0 connections`).
- **Belgelenmemiş macOS arayüzleri, açıkça.** Keeplight hangi özel fonksiyonları çağırdığını tek tek
  söyler. Her biri çalışma anında `dlsym` ile çözülür; eksik olan çökme yerine kendi özelliğini kapatır.

  | Nerede | Fonksiyonlar | Ne için |
  |---|---|---|
  | CoreGraphics (yedek olarak SkyLight) | `CGSGetNumberOfDisplayModes`, `CGSGetDisplayModeDescriptionOfLength`, `CGSGetCurrentDisplayMode`, `CGSConfigureDisplayMode`, `CGSConfigureDisplayEnabled` | HiDPI dahil her ekran modu; mod ayarlama; yazılımla bağlantı kesme ve yeniden bağlama |
  | DisplayServices (özel framework) | `DisplayServicesGetBrightness`, `DisplayServicesSetBrightness`, `DisplayServicesCanChangeBrightness` | dahili ve Apple ekranlarının parlaklığı |
  | CoreDisplay | `CoreDisplay_DisplayCreateInfoDictionary` | ekran adları ve konumları |
  | IOKit | `IOAVServiceCreateWithService`, `IOAVServiceReadI2C`, `IOAVServiceWriteI2C`, `IOAVServiceCopyEDID` | ekran kablosu üzerinden DDC/CI ve EDID (Apple silicon) |

  En düşüğün altına karartma açık CoreGraphics gama tablosu API'sini kullanır. Çekirdek eklentisi yok,
  yetkili yardımcı süreç yok, entitlement yok; System Integrity Protection'a dokunan hiçbir şey yok.
- **Neyi değiştirir.** Yalnız sizin istediğinizi: ekran modları ve düzeni, monitörlerinizdeki DDC/CI
  değerleri ve en düşüğün altına karartılan monitörün gama tablosu (%100'de, Keeplight kapanınca,
  Rescue'da ve Erase'de geri konur). `Open at login`, Keeplight'ı giriş öğesi olarak kaydeder.
- **Neyi saklar.** Tercihlerini ve `~/Library/Application Support/Keeplight` klasörünü (değişiklik
  günlüğü, bekleyen değişiklik, en son tuttuğunuz düzen, kestiği ekranlar, başlattığı yansıtmalar).
  Settings › About › `Erase All Keeplight Data…` hepsini siler.

## SSS

**Parlaklık tuşları neden Erişilebilirlik ister?** macOS parlaklık tuşlarını kendine gönderir; onlara
tepki vermek isteyen bir uygulama klavyeyi bir event tap ile izlemek zorundadır ve macOS buna yalnız
Erişilebilirlik izniyle izin verir. Keeplight'ın tap'i parlaklık tuşlarına (ve açtıysanız F1/F2'ye) bakar,
diğer her tuşu dokunmadan ve okumadan geçirir. Bir tuşa yalnız onunla bir DDC monitörü değiştirdiyse el
koyar; dahili ve Apple ekranlarında macOS'un kendi davranışı kalır.

**Keeplight monitörümün parlaklığını neden değiştiremiyor?** Panel o zaman `No brightness control`
gösterir; ⓘ nedenini söyler. Sık nedenler: DDC/CI monitörün kendi menüsünde kapalı; birçok dock ve bazı
adaptörler onu engeller, DisplayLink ve diğer USB ya da sanal ekranlar, AirPlay ve Sidecar'da hiç DDC yolu
yoktur; monitör bazı girişlerde ya da görüntü modlarında (HDR, eco) parlaklığı kilitler; ya da Mac bir
Intel Mac'tir ve Keeplight'ta orada henüz DDC/CI yok. `Check Again` monitöre yeniden sorar,
`keeplight doctor <ekran>` denediği her adımı gösterir.

**"En düşüğün altı" tam olarak ne yapıyor?** Yaklaşık 19'un üstünde kaydırıcı monitörün kendi
parlaklığıdır ve DDC/CI ile gönderilir. Altında monitör en düşük arka ışıkta kalır ve Keeplight ekranın
gama tablosunu küçültür, 0'da tam siyaha kadar. Görüntü kararır, arka ışık kararmaz: fazladan enerji
tasarrufu yoktur ve inerken kontrast da düşer. Kaydırıcıyı yükseltince, Keeplight kapanınca, Rescue'da ve
Erase'de tablo geri konur; uykudan sonra tam siyah bir monitör ilk adımda geri gelir, böylece uyanan Mac
ölü bir ekran gibi görünmez. Mac ekranında 0, macOS'taki gibi arka ışığı kapatır. CLI'ın
`brightness` komutu yalnız monitörün kendi aralığını kullanır.

**Bir çözünürlük değişikliğinden sonra ekran karardı.** Bekleyin: 15 saniye (seçtiyseniz 30) sonra
kendiliğinden geri döner. Bir ekran yanlış kalırsa <kbd>⌃⌥⌘R</kbd>'yi basılı tutun ya da Terminal'de
`keeplight rescue` çalıştırın. Keeplight açılırken <kbd>⇧</kbd>'yi basılı tutmak, açılışta uygulayacağı
her şeyi atlar.

**Özel arayüz kullanması riskli değil mi?** Ekran araçları genelde bunlara dayanır: macOS'ta bir ekranın
bağlantısını kesmenin ya da Apple silicon'da DDC/CI konuşmanın açık bir yolu yok. Keeplight onların var
olduğunu varsaymaz: her biri çalışma anında aranır, eksik olan yalnız kendi özelliğini kapatır ve
`keeplight interfaces` Mac'inizde neyin bulunduğunu gösterir. Bir macOS güncellemesi birinin davranışını
yine de değiştirebilir; riskli değişikliklerin Keep'i beklemesi ve Rescue'nun tek kısayol uzakta olması
bu yüzden.

**Intel Mac'lerde çalışır mı?** Evet, uygulama universal: çözünürlük, düzen ve Apple ekranı parlaklığı
çalışır. DDC/CI ile harici parlaklık ve en düşüğün altına karartma Apple silicon ister.

**Bir güncellemeden sonra parlaklık tuşları çalışmıyor.** Sürümler aynı Developer ID ile imzalanır, macOS
izni korur. Yerelde derlenen ad-hoc imzalı uygulama ise her build'de izni kaybeder: System Settings ›
Privacy & Security › Accessibility'de Keeplight'ı **−** ile kaldırın ve tuşları yeniden açın.

**Dotpitch kullanıyordum.** Keeplight 0.2'ye kadar Dotpitch adını taşıyordu. İlk açılışta Dotpitch'in
kayıtlı durumunu bir kez devralır (bekleyen geri alma, kesilmiş ekranlar, geçmiş, adlar); parlaklık
tuşları ve izinleri sıfırdan başlar.

**Bir yere bir şey gönderiyor mu?** Hayır. İçinde ağ kodu yok.

### Bilinen sınırlar

- Donanım davranışı (monitöre göre DDC zamanlaması, uyanma, tak-çıkar, Erişilebilirlik istemi)
  `swift test`'te taklitlerle sınanır, her monitörle değil; `keeplight doctor --markdown` bir issue için
  rapor hazırlar, seri numarasını son 3 karakterine kısaltır.
- Yazılımla bağlantı kesme, oturumu kapatana kadar sürer.

## Komut satırı

```sh
keeplight list
keeplight info main
keeplight modes main               # ham modların hepsi için --all
keeplight mode main 2560x1440@60 hidpi
keeplight main "DELL U2723QE"
keeplight mirror 1 0 && keeplight unmirror 1
keeplight brightness main 70       # monitörün kendi 0–100'ü
keeplight ddc main get volume
keeplight ddc main set input 0x0f
keeplight edid main --json
keeplight doctor main              # GitHub issue için --markdown (seri kısaltılır)
keeplight journal --since 1h
keeplight rescue --dry-run
keeplight interfaces               # özel macOS fonksiyonları ve bu Mac'teki durumları
```

Bir ekran; liste sırası, `id:<displayID>`, `main`, `builtin` ya da adının bir parçasıyla seçilir. Komut
satırından yapılan değişiklikler Keep kartı olmadan hemen uygulanır ve uygulamanınkilerle aynı günlüğe
yazılır. `disable` son etkin fiziksel ekranı kapatmayı reddeder. `keeplight help <komut>` her komutu
açıklar.

## Build ve test

```sh
swift build
swift test
scripts/bundle-app.sh                # dist/Keeplight.app + dist/keeplight; SIGN_IDENTITY yoksa ad-hoc
UNIVERSAL=1 scripts/bundle-app.sh    # arm64 + x86_64
scripts/check-bundle.sh              # paket: uygulama ve CLI var, render aracı yok, debug kancası yok
scripts/audit-network.sh             # sürüm binary'lerinde ağ sembolü ya da framework'ü yok
scripts/copy-budget.sh               # uygulamanın metni 560 kelimeyi aşmaz
scripts/render.sh                    # her yüzey ekran dışında → .build/render/*.png (debug aracı, pakete girmez)
scripts/release.sh                   # bakımcılar için: universal, Developer ID, notarize Keeplight.dmg
```

`bundle-app.sh` paketi önce `.build/bundle/` içinde kurar ve doğrular, ancak sonra `dist/`'i değiştirir;
başarısız bir çalıştırma `dist/`'e dokunmaz. Denetimlerin hiçbiri uygulamayı başlatmaz ya da bir ekrana
dokunmaz.

README görselleri üretilir: `swift tools/readme/render-logo.swift` (logo),
`python3 -I tools/readme/hero.py` (hareketli hero) ve `scripts/render.sh && swift
tools/readme/frame-screenshots.swift` (ekran görüntüleri ve Keep kartı GIF'i).

Belirtim [docs/SPEC.md](docs/SPEC.md)'de, tasarım [docs/design/v4-keeplight.md](docs/design/v4-keeplight.md)
ve [docs/design/v5-panel.md](docs/design/v5-panel.md)'de. Keeplight bağımsız bir uygulamadır: başka hiçbir
üründen kod, varlık ya da metin alınmadı.

## Lisans

[MIT](LICENSE) © 2026 Hasan Taha Ozlu
