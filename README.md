# 🔋 MacWake

**MacWake**, macOS için tasarlanmış, detaylı pil sağlığı, kullanım analizi ve şarj alışkanlıklarını takip eden şık bir menü bar ve masaüstü widget uygulamasıdır. Swift ve SwiftUI kullanılarak, macOS'in modern tasarım çizgilerine (glassmorphism, vibrant efektler) sadık kalınarak geliştirilmiştir.

---

## ✨ Özellikler

*   **📊 Detaylı Oturum Takibi (Current Session):** 
    *   Ekran açık kalma süresi (Screen On) ve uykuda geçen süre.
    *   Yeniden başlatma/kapatma tespiti ile kesintisiz veri bütünlüğü.
    *   %1 şarj başına düşen ortalama ekran süresi verimlilik hesaplaması.
*   **🖱️ Yarı Saydam Masaüstü Widget'ı:**
    *   Kilitlenebilir ve masaüstünde istenilen yere konumlandırılabilir yüzen widget.
    *   Apple tarzı dairesel pil seviyesi göstergesi.
    *   Anlık batarya sıcaklığı ve döngü sayısı (Cycle Count) takibi.
*   **🔌 Akıllı Güç Adaptörü Analizi:**
    *   Bağlı adaptörün anlık (dinamik) ve nominal gücünü (Watt) izleme.
    *   Apple Orijinal adaptör doğrulaması (MFI Check).
    *   Kullanılan port tespiti (MagSafe, USB-C veya Thunderbolt).
    *   Düşük verimli şarj durumlarında **Yavaş Şarj Uyarısı** (Slow Charging Alert).
    *   Kullanılan tüm şarj cihazlarının geçmiş kaydı ve kullanım sayıları (Adapter History).
*   **⏰ Hızlı Deşarj Bildirimleri (Fast Battery Drain):**
    *   Pildeyken son 10 dakika içindeki ani pil düşüşlerini (örn: %5 ve üzeri) algılayarak anında yerel bildirim gönderir.
*   **💫 iPhone Stili Şarj Animasyonu:**
    *   Şarj kablosu takıldığında ekranın ortasında beliren, anlık şarj yüzdesini gösteren şık bir geçiş animasyonu (Ayarlar panelinden açılıp kapatılabilir).
*   **🌀 Fan Hızı ve Geçmişi Takibi (Fan Status):**
    *   SMC (System Management Controller) üzerinden cihazın anlık fan devrini (RPM) okuma.
    *   Fanı olan cihazlarda son 1 saatlik fan hız değişim grafiği (Sparkline chart).
    *   MacBook Air gibi fansız (fanless) cihazlarda alternatif şık bilgilendirme paneli.
*   **🚀 Kolay Erişim & Otomatik Başlatma:**
    *   Girişte otomatik açılma (Launch at Login) seçeneği.
    *   Gelişmiş koyu/açık mod uyumlu dinamik renk paleti.

---

## 🛠️ Kurulum & Çalıştırma

### Gereksinimler
*   **macOS 14.0 (Sonoma)** veya üzeri bir macOS sürümü.
*   **Swift Command Line Tools** veya **Xcode** (Derleme işlemi için).

### Derleme ve Yükleme
Uygulamayı derlemek, yerel olarak kod imzalamak (codesign) ve `/Applications` (Uygulamalar) klasörüne taşımak için hazırlanan derleme betiğini kullanabilirsiniz:

```bash
# Proje dizinine gidin
cd MacWake

# Derleme betiğini çalıştırılabilir yapın ve çalıştırın
chmod +x build.sh
./build.sh
```

Betiğin çalışması tamamlandığında uygulama `/Applications/MacWake.app` olarak yüklenecek ve otomatik olarak çalıştırılabilir hale gelecektir.

### Manuel Terminal Komutları
Eğer uygulamayı terminalden yönetmek isterseniz:

*   **Uygulamayı Başlatma:**
    ```bash
    open /Applications/MacWake.app
    ```
*   **Uygulamayı Kapatma:**
    ```bash
    killall MacWake
    ```

---

## 📂 Proje Yapısı

*   `Sources/MacWakeApp.swift`: Uygulama yaşam döngüsü, menü bar entegrasyonu ve tekil örnek kontrolü.
*   `Sources/BatteryTracker.swift`: Güç durumu takibi (IOKit & IOPS), oturum verilerinin depolanması ve bildirim mantığı.
*   `Sources/SMCHelper.swift`: SMC (System Management Controller) donanım verilerini ve fan hızlarını doğrudan okuma modülü.
*   `Sources/MacWakeMenuView.swift`: Menü bar tıklandığında açılan ana arayüz bileşenleri ve zaman tüneli grafiği.
*   `Sources/WidgetWindow.swift`: Masaüstündeki yüzen widget penceresi, sürükleme mantığı ve dairesel gösterge.
*   `Sources/ChargingAnimation.swift`: Şarj kablosu takıldığında beliren tam ekran animasyon katmanı.
*   `Sources/LaunchAgentManager.swift`: macOS `SMAppService` API'si ile girişte çalıştırma ayarları.

---

## 🔒 Güvenlik & İzinler

Uygulamanın pil durumunu ve şarj adaptörlerini izleyebilmesi için herhangi bir yönetici (root) iznine ihtiyacı yoktur, tamamen standart macOS IOKit API'lerini kullanır. 
*   **Bildirimler:** Hızlı deşarj uyarılarını alabilmek için uygulama ilk açıldığında bildirim izni vermeniz önerilir (Menü altındaki "Enable/Settings" butonuyla kontrol edebilirsiniz).

---

## 📄 Lisans
Bu proje **Telif Hakkı Saklıdır (All Rights Reserved)** kapsamında lisanslanmıştır. Kaynak kodları, tasarımları ve derlenmiş sürümleri dahil tüm fikri mülkiyet hakları saklıdır. Bu yazılımın izinsiz kopyalanması, değiştirilmesi, dağıtılması veya App Store dahil herhangi bir platformda yayınlanması yasaktır.
