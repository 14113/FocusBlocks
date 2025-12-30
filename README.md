# FocusBlocks

Minimalistická menu bar appka pro focus bloky.

## Funkce

- 10 bloků × 30 minut
- 5 min pauza mezi bloky s návrhy aktivit
- Vizuální počítadlo v menu baru
- Focus Mode integrace (přes Shortcuts)
- **RescueTime integrace** - automaticky startuje/ukončuje FocusTime session
- Po 10. bloku: jasný signál "DOST"
- Automatický reset každý den

## Instalace

### 1. Vytvoř Shortcuts pro Focus Mode

V aplikaci **Shortcuts** vytvoř dva shortcuts:

**"Start Focus":**
- Add action: "Set Focus"
- Focus: "Do Not Disturb" (nebo vlastní Focus profil)
- Turn: On

**"Stop Focus":**
- Add action: "Set Focus"
- Focus: "Do Not Disturb"
- Turn: Off

### 2. RescueTime API Key (volitelné)

1. Jdi na https://www.rescuetime.com/anapi/manage
2. Vygeneruj nový API key
3. Vlož ho do nastavení v appce

### 3. Build appky

Otevři Xcode projekt:
```bash
cd FocusBlocks
open FocusBlocks.xcodeproj
```

V Xcode:
1. Cmd+B pro build
2. Product → Archive pro release verzi
3. Nebo prostě Cmd+R pro spuštění

**Poznámka:** Swift Package Manager build (`swift build`) nefunguje kvůli UserNotifications - vyžaduje proper app bundle.

### 4. Spuštění

Po buildu v Xcode se appka spustí automaticky. Pro ruční spuštění:

1. Najdi `FocusBlocks.app` v `~/Library/Developer/Xcode/DerivedData/FocusBlocks-*/Build/Products/Debug/`
2. Přesuň do `/Applications`
3. Přidej do Login Items (System Settings → General → Login Items)

## Použití

1. Klikni na ikonu v menu baru
2. Klikni "Start" pro začátek bloku
3. Po 30 minutách dostaneš notifikaci a začne 5min pauza
4. Po pauze můžeš začít další blok
5. Po 10. bloku: zavři notebook

## Konfigurace

V `TimerManager.swift` můžeš upravit:

```swift
let maxBlocks = 10           // max bloků za den
let blockDuration = 30 * 60  // délka bloku (v sekundách)
let breakDuration = 5 * 60   // délka pauzy (v sekundách)

let activities = [           // seznam aktivit pro pauzy
    "🚶 Procházka",
    "📖 Čtení knihy",
    // ...
]
```

## Poznámky

- Appka si pamatuje stav přes UserDefaults
- Počítadlo se resetuje každý den automaticky
- Focus Mode se ovládá přes Shortcuts (musíš je vytvořit ručně)
