# 🔋 MacWake

[English](README.md) | [简体中文](README.zh-Hans.md) | [Türkçe](README.tr.md) | [日本語](README.ja.md) | [한국어](README.ko.md)

**MacWake**, ayrıntılı pil sağlığını, kullanım analizlerini ve şarj alışkanlıklarını izlemek için macOS'e yönelik tasarlanmış zarif bir menü çubuğu ve masaüstü araç takımı uygulamasıdır. Swift ve SwiftUI ile geliştirilen uygulama, modern macOS tasarım yönergelerini (cam morfizmi, canlı efektler) aslına uygun biçimde benimser.

<p align="center">
  <img src="Screenshots/menubar-popover.png" alt="MacWake menü çubuğu paneli" width="380">
</p>

---

## 🖥️ Dynamic Island ve Menü Çubuğu

Çentikte bir **Dynamic Island** yer alır: daraltılmış durumdayken donanımla bütünleşir, imleç üzerine geldiğinde veya tıklandığında esnek bir yay hareketiyle genişler ve dokunsal geri bildirim verir. Canlı güç değerlerini, pil sağlığını ve pil sıcaklığını gösterirken araç takımı, oturum sıfırlama, animasyonlar ve bildirimler için hızlı anahtarlar da sunar.

<p align="center">
  <img src="Screenshots/dynamic-island.png" alt="MacWake Dynamic Island" width="760">
</p>

**Menü çubuğu** gerçek zamanlı güç tüketimini bir bakışta gösterir (yukarıda gösterildiği gibi); tıklandığında Oturum, Geçmiş, Donanım ve Ayarlar bölümlerinden oluşan tam paneli açar.

<p align="center">
  <img src="Screenshots/menubar-item.png" alt="MacWake menü çubuğu öğesi" height="26">
</p>

---

## ✨ Özellikler

*   **🔋 Şarj Sınırı (tüm Apple Silicon M serisi):**
    *   Uzun vadeli pil aşınmasını azaltmak için şarjı %50 ile %95 arasındaki herhangi bir düzeyde sınırlar.
    *   Her çip için en iyi yöntemi seçer: M1/M2/M3'te temiz şarj engelleme (CHTE/CH0C), M4'te adaptör denetimi (CHIE) — notarizasyonu yapılmış küçük bir arka plan yardımcısı aracılığıyla (bir defalık onay, parola istemi yok).
    *   **⛵ Yelken Modu:** Üst sınırda mikro şarj yapmak yerine, yeniden şarj etmeden önce pilin alt sınıra kadar düşmesine izin verir — daha az döngü, daha az ısı.
    *   **🧪 Derin Pil Kalibrasyonu:** Yakıt göstergesini yeniden kalibre etmek için tam bir döngü uygular — yaklaşık %15'e kadar boşaltır, %100'e kadar şarj eder ve bir saat bekletir — işlem bir programa göre veya “Şimdi Kalibre Et” seçeneğiyle başlatılabilir (canlı aşama durumu ve İptal düğmesiyle).
*   **⌨️ Komut satırı aracı:**
    *   Ayarlar'dan `macwake` CLI aracını yükleyin ve şarjı Terminal üzerinden denetleyin: `macwake status`, `charging on|off`, `adapter on|off`, `energy auto|low|high`, `fan auto|<rpm>`.
*   **⚡️ Enerji Modu:**
    *   macOS Enerji Modu'nu (Otomatik / Düşük Güç / Yüksek Güç) doğrudan menüden değiştirin — Yüksek Güç yalnızca destekleyen Mac'lerde gösterilir.
*   **🌀 İzleme sekmesi — Fan + En Çok Kullanan Uygulamalar:**
    *   Fan durumu, bir saatlik hız geçmişi ve elle belirlenen hedef RPM (deneysel — 92°C'nin üzerinde otomatik olarak sistem denetimine döner) kendi sekmesinde yer alır.
    *   Çalışan uygulamaları CPU veya RAM kullanımına göre sıralar; Activity Monitor / iStat Menus gibi yalnızca istendiğinde örnekleme yapar.
*   **🎯 Ek Akıllı Şarj Özellikleri:**
    *   Tek dokunuşla sınır ön ayarları (%60/%70/%80/%90), seyahat günleri için tek seferlik “Bu Kez %100'e Şarj Et” geçersiz kılma seçeneği ve Programa Göre Tam Şarj — her gün seçtiğiniz saatte %100 şarjla hazır olur.
    *   Isı Koruması, sıcaklık 40°C'yi aştığında şarjı duraklatır ve pil soğuduğunda sürdürür.
    *   Seçtiğiniz düzeyde, macOS'in kendi uyarısından önce gösterilen özel düşük pil uyarısı.
*   **⚡️ Shortcuts ve Araç Takımı:**
    *   Shortcuts uygulaması eylemleri: Şarj Sınırını Ayarla, Bu Kez %100'e Şarj Et, Temizlik Modunu Başlat, Pil Durumunu Al.
    *   Pil halkası, pil sağlığı, sıcaklık ve sınır durumunu gösteren yerel macOS araç takımı (küçük ve orta).
    *   Pil sağlığı/döngü geçmişinizi, oturumları ve adaptör günlüğünü CSV olarak dışa aktarın.
*   **🎛️ Özelleştirilebilir Menü Çubuğu:**
    *   Menü çubuğu öğesinde tam olarak ne gösterileceğini seçin — simge, pil yüzdesi, güç/zaman, tahmini kalan süre ve sıcaklık — canlı önizlemeyle.
*   **🏝️ Dynamic Island (Çentik UI):**
    *   Fiziksel çentiği saran ve daraltıldığında donanımla bütünleşen panel.
    *   İmleç üzerine geldiğinde veya tıklandığında esnek bir yay animasyonu ve dokunsal geri bildirimle genişler.
    *   Dönen işaret halkaları ve şarj gücüyle titreşen parlak bir çekirdeğe sahip **JARVIS tarzı ark reaktörü HUD**.
    *   Güç, pil sağlığı ve sıcaklığı bir bakışta gösterir; ayrıca hızlı anahtarlar sunar (araç takımı, sıfırlama, animasyonlar, bildirimler).
*   **🌍 Yerelleştirme:**
    *   İngilizce, Türkçe, Basitleştirilmiş Çince (简体中文), Japonca (日本語) ve Korece (한국어) için eksiksiz UI desteği. macOS sistem dilini kullanın veya MacWake Ayarları'ndan bir dil seçin; değişikliği uygulamak için yeniden başlatın. WidgetKit uzantısı, sistem tarafından sağlanan kendi dil ortamını kullanmaya devam eder.
*   **📊 Ayrıntılı Oturum Takibi (Geçerli Oturum):**
    *   Ekranın açık kaldığı süreyi ve uyku süresini izler.
    *   Yeniden başlatma/kapatma algılamasıyla kesintisiz veri bütünlüğü sağlar.
    *   Pildeki her %1'lik düşüş başına ortalama ekran süresini gösteren verimlilik hesabı yapar.
*   **🖱️ Yarı Saydam Masaüstü Araç Takımı:**
    *   Kilitlenebilen ve masaüstünde herhangi bir yere konumlandırılabilen yüzer araç takımı.
    *   Apple tarzı dairesel pil düzeyi göstergesi.
    *   Gerçek zamanlı pil sıcaklığı ve döngü sayısı izleme.
*   **🔌 Akıllı Güç Adaptörü Analizi ve Hibrit Algoritma:**
    *   **⚡️ Hibrit Güç Tüketimi:** Güç adaptörüne bağlıyken toplam sistem güç tüketimini (`SystemPowerIn`), pille çalışırken boşalma hızını (`InstantAmperage`) sorunsuz biçimde birleştirerek menü çubuğunda Watt cinsinden gerçek zamanlı (dinamik) güç tüketimini root (`sudo`) ayrıcalıkları gerektirmeden doğru şekilde gösterir.
    *   Bağlı adaptörün nominal watt değerini (ör. 30W) ve gerçek şarj durumunu izler.
    *   Apple orijinal adaptör doğrulaması (MFI Check).
    *   Kullanılan bağlantı noktasını belirler (MagSafe, USB-C veya Thunderbolt).
    *   Düşük verimli şarj senaryoları için **Yavaş Şarj Uyarısı**.
    *   Geçmişteki tüm şarj cihazlarının kullanım sayısını izlemek için Adaptör Geçmişi kaydı.
*   **⏰ Hızlı Pil Boşalması Bildirimleri:**
    *   Pille çalışırken son 10 dakika içindeki ani pil düşüşlerini (ör. %5 veya daha fazla) algılar ve hemen yerel bildirim gönderir.
*   **💫 iPhone Tarzı Şarj Animasyonu:**
    *   Şarj kablosu takıldığında ekranın ortasında görünen, geçerli yüzdeyi gösteren zarif bir tam ekran geçiş animasyonu (ayarlardan açılıp kapatılabilir).
*   **🛡️ Akıllı Pil Koruması ve Sıcaklık Uyarıları:**
    *   Pil sıcaklığı 38°C eşiğini aştığında hemen görsel bir uyarı kartı ve yerel bildirim gösterir.
    *   Aygıt aralıksız 24 saatten uzun süre güç kaynağına bağlı ve şarjı %99 veya üzeri düzeyde kalırsa pil sağlığını korumak için boşaltma uyarısı verir.
*   **📈 Pil Sağlığı Düşüş Günlüğü:**
    *   Maksimum pil kapasitesi her değiştiğinde tarih ve döngü sayısını kaydeden otomatik geçmiş günlüğü.
    *   Donanım sekmesinde geriye dönük kapasite düşüşünü şık bir zaman çizelgesiyle gösterir.
*   **🚀 Kolay Erişim ve Otomatik Başlatma:**
    *   Oturum açıldığında otomatik olarak başlatma seçeneği.
    *   Koyu/açık modlarla uyumlu gelişmiş dinamik renk paleti.

---

## 🛠️ Kurulum

### Seçenek 1 — Homebrew (Önerilen)

```bash
brew tap Jarvis322/tap
brew install --cask macwake
```

### Seçenek 2 — Doğrudan İndirme

En yeni `Wake-1.0.dmg` dosyasını [GitHub Releases](https://github.com/Jarvis322/MacWake/releases) sayfasından indirin, DMG'yi açın ve **MacWake.app** uygulamasını Applications klasörünüze sürükleyin.

### Gereksinimler
*   **macOS 14.0 (Sonoma)** veya daha yenisi
*   Apple Silicon veya Intel

### Manuel Terminal Komutları
Uygulamayı komut satırı üzerinden yönetmek isterseniz:

*   **Uygulamayı Başlatmak İçin:**
    ```bash
    open /Applications/MacWake.app
    ```
*   **Uygulamadan Çıkmak İçin:**
    ```bash
    killall MacWake
    ```

---

## 📂 Proje Yapısı

*   `Sources/MacWakeApp.swift`: Uygulama yaşam döngüsü, menü çubuğu entegrasyonu ve tek uygulama örneği yönetimi.
*   `Sources/BatteryTracker.swift`: Güç durumu takibi (IOKit ve IOPS), oturum verisi depolama ve bildirim mantığı.
*   `Sources/MacWakeMenuView.swift`: Ana UI bileşenleri ve menü çubuğu simgesine tıklandığında gösterilen zaman çizelgesi grafikleri.
*   `Sources/WidgetWindow.swift`: Yüzer masaüstü araç takımı penceresi, sürükleme mantığı ve dairesel gösterge.
*   `Sources/ChargingAnimation.swift`: Şarj kablosu bağlandığında tetiklenen tam ekran animasyon katmanı.
*   `Sources/LaunchAgentManager.swift`: macOS `SMAppService` API'sini kullanan oturum açma öğesi yapılandırması.

---

## ❤️ Destek

MacWake ücretsizdir; uygulamayı boş zamanlarımda geliştiriyorum. Pilinize yardımcı oluyorsa [GitHub üzerinden sponsor olmayı](https://github.com/sponsors/Jarvis322) düşünebilirsiniz — bu, geliştirme çalışmalarının sürmesini doğrudan destekler.

---

## 🔒 Güvenlik ve İzinler

Uygulama, pil durumunu ve şarj adaptörlerini izlemek için hiçbir yönetici (root) ayrıcalığı gerektirmez; tamamen standart macOS IOKit API'lerine dayanır.
*   **Bildirimler:** Hızlı boşalma uyarılarını almak için uygulama ilk kez başlatıldığında bildirim izinlerinin verilmesi önerilir (bu ayar, Menü altındaki “Etkinleştir/Ayarlar” düğmesinden yönetilebilir).

---

## 📄 Lisans
Bu proje **All Rights Reserved** kapsamında lisanslanmıştır. Kaynak kodu, tasarımlar ve derlenmiş sürümler dâhil olmak üzere tüm fikrî mülkiyet hakları yazara aittir. Kaynak kodunun izinsiz kopyalanması, değiştirilmesi veya yeniden dağıtılması yasaktır. Yazar, Mac App Store dâhil olmak üzere MacWake'i yayımlama ve dağıtma konusunda münhasır hakka sahiptir.
