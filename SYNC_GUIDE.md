# Průvodce synchronizací FocusBlocks

## Přehled

FocusBlocks nyní podporuje **real-time** automatickou synchronizaci dat mezi více počítači pomocí Dropboxu. Všechna vaše data (dokončené bloky, časy, nastavení a **běžící timer**) jsou automaticky synchronizována bez nutnosti manuálního exportu/importu.

## Jak to funguje

1. **Automatické ukládání**: Data se ukládají do JSON souboru ve vybrané Dropbox složce
2. **Sledování změn**: Aplikace sleduje změny v souboru a automaticky načítá aktualizace
3. **Real-time timer sync**: Když spustíte timer na jednom počítači, druhý počítač ho automaticky načte
4. **Periodická synchronizace**: Každých 10 sekund se synchronizuje stav timeru
5. **Inteligentní slučování**: Pokud pracujete na dvou počítačích současně, aplikace chytře sloučí data

## Nastavení synchronizace

### První nastavení

1. Nainstalujte Dropbox na váš počítač (pokud ještě není)
2. Otevřete FocusBlocks
3. Klikněte na **"Nastavení"** v dolní části okna
4. Najděte sekci **"Synchronizace dat"**
5. Zapněte přepínač synchronizace
6. Vyberte složku v Dropboxu (doporučeno: `~/Dropbox/FocusBlocks/`)
7. Aplikace vytvoří soubor `focusblocks-data.json` v této složce

### Nastavení na druhém počítači

1. Ujistěte se, že Dropbox je nainstalován a synchronizován
2. Otevřete FocusBlocks na druhém počítači
3. Zapněte synchronizaci v Nastavení
4. **Vyberte STEJNOU složku** jako na prvním počítači
5. Aplikace automaticky načte existující data

## Řešení konfliktů

Aplikace používá inteligentní strategie pro sloučení dat, když pracujete na více počítačích:

### Dokončené bloky
- **Strategie: MERGE (Sloučit)**
- Všechny dokončené bloky z obou počítačů se sloučí
- Duplikáty se automaticky odstraní
- Bloky se seřadí chronologicky
- ✅ **Žádná ztráta dat** - všechny vaše bloky jsou zachovány

### Nastavení
- **Strategie: LAST-WRITE-WINS (Vítězí poslední)**
- Použijí se nastavení z počítače, který je změnil jako poslední
- Dostanete notifikaci, když se nastavení změní
- 📢 Pokud změníte nastavení, změní se na všech počítačích

### Běžící timer
- **Strategie: PREFER-LOCAL (Preferovat lokální)**
- Pokud timer běží na jednom počítači, druhý ho automaticky načte
- Pokud timer již běží lokálně, ignoruje vzdálený timer
- Synchronizace každých 10 sekund
- ⏱️ **Real-time**: Uvidíte běžící timer na všech počítačích
- 🔄 **Indikátor sync**: Ikona ukazuje, že timer byl synchronizován

## Příklad použití

### Scénář 1: Práce z domova a z kanceláře
```
8:00 - Domácí počítač: Dokončíte 2 bloky
10:00 - Přijdete do kanceláře
10:01 - Kancelářský počítač: Automaticky načte 2 bloky z domova
12:00 - Kancelářský počítač: Dokončíte další 3 bloky
15:00 - Vrátíte se domů
15:01 - Domácí počítač: Automaticky načte všech 5 bloků (2+3)
```

### Scénář 2: Real-time synchronizace timeru
```
9:00 - Počítač A: Kliknete na Start
9:00 - Počítač B: Do 10 sekund uvidíte běžící timer ⏱️
9:15 - Počítač B: Uvidíte timer na 15:00 zbývá
9:30 - Počítač A: Blok dokončen
9:30 - Počítač B: Automaticky načte dokončený blok
```

### Scénář 3: Konflikt nastavení
```
Počítač A: Změníte focus čas na 45 minut (9:00)
Počítač B: Změníte focus čas na 25 minut (9:05)
Výsledek: Použije se 25 minut (novější změna)
```

### Scénář 4: Konflikt běžícího timeru
```
9:00 - Počítač A: Start timer (běží)
9:05 - Počítač B: Není připojen k internetu
9:05 - Počítač B: Start timer (běží lokálně)
9:10 - Počítač B: Připojí se k internetu
Výsledek: Pokračuje lokální timer na Počítači B
         (preferuje lokální před vzdáleným)
```

## Datový soubor

### Struktura
Soubor `focusblocks-data.json` obsahuje:
```json
{
  "version": 1,
  "lastModified": "2026-01-23T10:30:00Z",
  "deviceId": "unique-device-identifier",
  "data": {
    "completedBlockTimes": [1737627000.0, 1737628800.0],
    "lastDate": 1737590400.0,
    "settings": {
      "focusDurationMinutes": 30,
      "breakDurationMinutes": 5,
      "reminderMinutes": 15,
      "maxBlocks": 10,
      "openRescueTimeOnComplete": true,
      "rescueTimeApiKey": "..."
    },
    "timerState": {
      "isRunning": true,
      "isOnBreak": false,
      "blockStartTime": 1737627000.0,
      "breakStartTime": null,
      "sourceDeviceId": "device-A-uuid",
      "stateUpdatedAt": 1737627000.0
    }
  }
}
```

### Umístění
- Typicky: `~/Dropbox/FocusBlocks/focusblocks-data.json`
- Můžete zvolit jakoukoli složku v Dropboxu

## Technické detaily

### Jak funguje sledování změn
- Aplikace používá **File System Events** pro sledování změn
- Když Dropbox stáhne změny, aplikace je detekuje do 1 sekundy
- Čekací doba 500ms zajišťuje, že Dropbox dokončí zápis

### Periodická synchronizace
- **Real-time timer sync**: Každých 10 sekund
- Automaticky synchronizuje běžící timer, pauzu a zbývající čas
- Minimální zátěž na Dropbox (malý JSON soubor)
- Funguje pouze když je synchronizace zapnutá

### Bezpečnost
- Data jsou uložena pouze lokálně ve vašem Dropboxu
- Žádná cloudová služba třetí strany
- Soukromí dat je zachováno (včetně RescueTime API klíče)

### Device ID
- Každý počítač má unikátní identifikátor
- Pomáhá rozlišovat, odkud změny přišly
- Automaticky generován při prvním spuštění

## Řešení problémů

### Synchronizace nefunguje
1. **Zkontrolujte Dropbox**:
   - Je Dropbox spuštěný?
   - Je složka synchronizována? (zelené fajfky)

2. **Zkontrolujte oprávnění**:
   - Má aplikace přístup ke složce?
   - Zkuste vybrat složku znovu

3. **Zkontrolujte soubor**:
   - Existuje `focusblocks-data.json` ve složce?
   - Je soubor platný JSON? (otevřete v textovém editoru)

### Duplikované bloky
- Teoreticky nemožné díky merge logice
- Pokud se objeví, zkuste:
  1. Vypnout synchronizaci
  2. Smazat `focusblocks-data.json`
  3. Zapnout synchronizaci znovu

### Nastavení se mění neočekávaně
- Strategie LAST-WRITE-WINS znamená, že novější změny vítězí
- Změňte nastavení pouze na jednom počítači najednou
- Počkejte 1-2 sekundy, než se změní na druhém počítači

## Často kladené otázky

### Q: Musím mít placenou verzi Dropboxu?
**A:** Ne, free tier (2 GB) je dostatečný. Soubor je velmi malý (~1 KB).

### Q: Funguje to s jinými cloud službami?
**A:** Teoreticky ano - OneDrive, iCloud Drive, Google Drive - ale testováno pouze s Dropboxem.

### Q: Co když nemám internet?
**A:** Aplikace funguje offline. Data se synchronizují, až budete online.

### Q: Můžu používat více než 2 počítače?
**A:** Ano! Synchronizace funguje s libovolným počtem počítačů.

### Q: Je synchronizace bezpečná?
**A:** Ano. Data jsou šifrována Dropboxem pomocí AES-256. Aplikace pouze čte/zapisuje do vaší osobní složky.

### Q: Co když smažu soubor?
**A:** Aplikace ho automaticky vytvoří znovu s aktuálními daty z počítače.

### Q: Uvidím běžící timer na druhém počítači?
**A:** Ano! Když spustíte timer na jednom počítači, druhý ho automaticky načte do 10 sekund. Uvidíte ikonu sync (🔄) když je timer synchronizován z jiného zařízení.

### Q: Co se stane když spustím timer na obou počítačích současně?
**A:** Aplikace preferuje lokální timer. Pokud již timer běží na vašem počítači, ignoruje vzdálený timer z druhého zařízení.

### Q: Jak rychlá je real-time synchronizace?
**A:** Timer se synchronizuje každých 10 sekund. To znamená maximální zpoždění 10 sekund mezi počítači.

### Q: Zvýší periodická synchronizace spotřebu baterie?
**A:** Ne výrazně. Synchronizace běží pouze když je zapnutá a zapisuje malý JSON soubor (~2 KB) každých 10 sekund.

## Podpora

Pokud narazíte na problém, můžete:
1. Zkontrolovat tento průvodce
2. Zkontrolovat macOS Console.app pro logy aplikace
3. Vytvořit issue na GitHub repozitáři
