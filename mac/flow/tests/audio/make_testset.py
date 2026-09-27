#!/usr/bin/env python3
"""Festes Testset fuer das Release-Tor (scripts/release.sh) – einmal erzeugt und eingecheckt.

    python3 tests/audio/make_testset.py          fehlende Dateien erzeugen (vorhandene bleiben)
    python3 tests/audio/make_testset.py --force  alles neu (danach Baselines neu: scripts/release.sh --rebaseline)

Nur macOS-Sprachausgabe (`say`), keine echten Aufnahmen, keine persoenlichen Namen: alle Namen stammen aus einem
neutralen Test-Woerterbuch (dictionary.json). 16 kHz mono WAV.

  rec/      Erkennung (WER, Namen, Latenz): DE/EN, kurz und lang (bis ~30 s), verschiedene Stimmen, teils verrauscht
  voice/    Stimmabgleich: enroll.wav + own/*.wav = Teststimme („eigene“ Stimme), foreign.wav = fremde Stimme
Nur Python-Standardbibliothek (laeuft auch mit /usr/bin/python3).
"""
import array, json, math, os, random, subprocess, sys, wave

HERE = os.path.dirname(os.path.abspath(__file__))
FORCE = "--force" in sys.argv

# Neutrales Test-Woerterbuch (erfundene/allgemeine Namen – nichts Persönliches)
DICTIONARY = [
    {"heard": "Okonkwo", "write": "Okonkwo", "vocabOnly": True},
    {"heard": "Adebayo", "write": "Adebayo", "vocabOnly": True},
    {"heard": "Lumora", "write": "Lumora", "vocabOnly": True},
    {"heard": "Brenninkmeyer", "write": "Brenninkmeyer", "vocabOnly": True},
    {"heard": "Dufresne", "write": "Dufresne", "vocabOnly": True},
    {"heard": "Kita Net", "write": "KiTaNet"},
    {"heard": "Kitanet", "write": "KiTaNet"},
    {"heard": "Whisper Flow", "write": "Flow"},
    {"heard": "Clip Vault", "write": "ClipVault"},
]

# (id, lang, voice, rate, truth, tts-Schreibweise oder None, names, noisy)
REC = [
    ("de_s1", "de", "Anna", 185, "Schick Okonkwo bitte die neue Liste.", None, ["Okonkwo"], False),
    ("de_s2", "de", "Eddy (Deutsch (Deutschland))", 195, "Das Treffen mit Lumora ist am Dienstag um neun.", None, ["Lumora"], True),
    ("de_s3", "de", "Flo (Deutsch (Deutschland))", 205, "Okay, passt so.", None, [], False),
    ("de_s4", "de", "Sandy (Deutsch (Deutschland))", 180, "Kannst du Frau Brenninkmeyer kurz zurückrufen?", None, ["Brenninkmeyer"], True),
    ("de_s5", "de", "Anna", 200, "Wir fahren morgen früh nach Wolfenbüttel.", None, ["Wolfenbüttel"], False),
    ("de_s6", "de", "Eddy (Deutsch (Deutschland))", 175, "Ja, mach das bitte so.", None, [], False),
    ("de_l1", "de", "Anna", 180,
     "Ich habe gestern mit Adebayo über das Budget von KiTaNet gesprochen, und wir brauchen bis Freitag eine neue Übersicht "
     "mit allen Stunden, damit Pierre Dufresne die Zahlen noch vor dem Wochenende prüfen kann.",
     "Ich habe gestern mit Adebayo über das Budget von Kita Net gesprochen, und wir brauchen bis Freitag eine neue Übersicht "
     "mit allen Stunden, damit Pierre Dufresne die Zahlen noch vor dem Wochenende prüfen kann.",
     ["Adebayo", "KiTaNet", "Dufresne"], False),
    ("de_l2", "de", "Flo (Deutsch (Deutschland))", 190,
     "Heute Morgen war ich zuerst joggen, danach habe ich gefrühstückt und dann direkt mit der Arbeit angefangen, weil für das "
     "Projekt von Lumora noch einiges erledigt werden muss. Am Nachmittag kommt dann noch Besuch aus Wolfenbüttel.",
     None, ["Lumora", "Wolfenbüttel"], True),
    ("de_l3", "de", "Eddy (Deutsch (Deutschland))", 185,
     "Also für den neuen Bereich möchte ich, dass man die eigene Stimme einlernen kann und dass es mehrere Stufen gibt, sodass "
     "das System die Stimme mit der Zeit immer besser kennt. Außerdem soll Okonkwo die Texte noch einmal gegenlesen, bevor wir "
     "sie an Frau Brenninkmeyer schicken. Das wäre für mich wirklich wichtig.",
     None, ["Okonkwo", "Brenninkmeyer"], False),
    ("de_xl", "de", "Sandy (Deutsch (Deutschland))", 175,
     "Kurzes Update zum Projekt: Das Portal für KiTaNet ist seit heute Morgen online, und Adebayo hat die ersten Rückmeldungen "
     "schon gesammelt. Die meisten Eltern finden sich gut zurecht, nur die Anmeldung dauert noch zu lange. Pierre Dufresne "
     "schaut sich das morgen an. Danach schicken wir Frau Brenninkmeyer eine kurze Zusammenfassung, und am Freitag besprechen "
     "wir mit dem ganzen Team von Lumora, was als Nächstes kommt.",
     "Kurzes Update zum Projekt: Das Portal für Kita Net ist seit heute Morgen online, und Adebayo hat die ersten Rückmeldungen "
     "schon gesammelt. Die meisten Eltern finden sich gut zurecht, nur die Anmeldung dauert noch zu lange. Pierre Dufresne "
     "schaut sich das morgen an. Danach schicken wir Frau Brenninkmeyer eine kurze Zusammenfassung, und am Freitag besprechen "
     "wir mit dem ganzen Team von Lumora, was als Nächstes kommt.",
     ["KiTaNet", "Adebayo", "Dufresne", "Brenninkmeyer", "Lumora"], True),
    ("en_s1", "en", "Samantha", 185, "Send Okonkwo the updated budget.", None, ["Okonkwo"], False),
    ("en_s2", "en", "Eddy (Englisch (USA))", 195, "Sounds good, thanks.", None, [], True),
    ("en_s3", "en", "Flo (Englisch (USA))", 180, "The Lumora team needs the report by Friday afternoon.", None, ["Lumora"], False),
    ("en_s4", "en", "Samantha", 200, "Can you ask Adebayo to call me back?", None, ["Adebayo"], True),
    ("en_l1", "en", "Eddy (Englisch (USA))", 185,
     "KiTaNet is building a new portal, and Pierre Dufresne wants weekly budget numbers with a short explanation for anything "
     "that goes over budget, so please send them before Thursday night.",
     "Kita Net is building a new portal, and Pierre Dufresne wants weekly budget numbers with a short explanation for anything "
     "that goes over budget, so please send them before Thursday night.",
     ["KiTaNet", "Dufresne"], False),
    ("en_l2", "en", "Samantha", 190,
     "I think we should move the whole thing to local models, because the latency is much better and nothing ever leaves the "
     "laptop. Adebayo agrees, and Okonkwo wants to test it next week with the full team.",
     None, ["Adebayo", "Okonkwo"], True),
    ("en_l3", "en", "Flo (Englisch (USA))", 175,
     "The transcription should be faster without getting worse, so we benchmark every engine first and then decide which one "
     "to use for which clip. That way the short dictations feel instant, and the long ones stay accurate.",
     None, [], False),
]

# Stimmabgleich: „eigene“ Teststimme + fremde Stimme
OWN_DE = "Rocko (Deutsch (Deutschland))"
OWN_EN = "Rocko (Englisch (USA))"
FOREIGN = "Anna"
VOICE = [
    ("voice/enroll.wav", OWN_DE, 185,
     "Das ist meine Stimme für das Stimmprofil. Ich lese diesen Text ruhig und deutlich vor, damit das System lernt, wie ich klinge. "
     "Heute ist ein ganz normaler Tag, ich schreibe ein paar Nachrichten, beantworte E-Mails und plane die nächste Woche. "
     "Danach gehe ich noch kurz einkaufen und rufe am Abend meine Eltern an."),
    ("voice/own/own_de_short.wav", OWN_DE, 190, "Kannst du mir bitte die Unterlagen schicken?"),
    ("voice/own/own_de_names.wav", OWN_DE, 185, "Schick das bitte an Okonkwo und frag Adebayo, ob Lumora am Freitag Zeit hat."),
    ("voice/own/own_de_mid.wav", OWN_DE, 185,
     "Ich schaue mir die Liste heute Abend an und melde mich morgen früh bei dir, dann können wir alles in Ruhe besprechen."),
    ("voice/own/own_en_long.wav", OWN_EN, 185,
     "I will review the numbers tonight and send you a short summary tomorrow morning. If anything looks wrong, we can talk about it "
     "on Friday. After that, I would like to plan the next release together and write down who does what."),
    ("voice/foreign.wav", FOREIGN, 185, "Das ist eine fremde Stimme aus einem Video im Hintergrund, die nicht im Diktat landen soll."),
]

rng = random.Random(7)


def say_wav(voice, rate, text, wav):
    aiff = wav + ".aiff"
    subprocess.run(["say", "-v", voice, "-r", str(rate), "-o", aiff, text], check=True)
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, wav], check=True)
    os.remove(aiff)


def read(wav):
    with wave.open(wav) as w:
        a = array.array("h"); a.frombytes(w.readframes(w.getnframes()))
    return [x / 32768.0 for x in a]


def write(wav, x):
    a = array.array("h", [int(max(-1.0, min(1.0, v)) * 32767) for v in x])
    with wave.open(wav, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(a.tobytes())


def pad(x):
    """Stille davor/danach wie beim Taste-Halten (0,25 s / 0,3 s)."""
    return [0.0] * 4000 + x + [0.0] * 4800


def degrade(x, snr_db):
    """Laptop-Mikro: leiser, kurzer Hall, Rauschen mit festem Startwert (reproduzierbar)."""
    x = [v * 0.4 for v in x]
    d1, d2 = int(0.021 * 16000), int(0.047 * 16000)
    y = [x[i] + (0.18 * x[i - d1] if i >= d1 else 0) + (0.09 * x[i - d2] if i >= d2 else 0) for i in range(len(x))]
    loud = [v for v in y if abs(v) > 0.005]
    sp = math.sqrt(sum(v * v for v in loud) / max(1, len(loud)))
    sigma = sp / (10 ** (snr_db / 20))
    prev = 0.0
    out = []
    for v in y:
        n = rng.gauss(0, sigma)
        prev = 0.7 * prev + 0.3 * n          # etwas tieffrequenter als weisses Rauschen
        out.append(v + prev * 1.6)
    return out


def main():
    os.makedirs(os.path.join(HERE, "rec"), exist_ok=True)
    os.makedirs(os.path.join(HERE, "voice", "own"), exist_ok=True)
    items = []
    for cid, lang, voice, rate, truth, tts, names, noisy in REC:
        rel = f"rec/{cid}.wav"
        wav = os.path.join(HERE, rel)
        if FORCE or not os.path.exists(wav):
            say_wav(voice, rate, tts or truth, wav)
            x = pad(read(wav))
            if noisy:
                x = degrade(x, 16)
            write(wav, x)
        dur = len(read(wav)) / 16000
        items.append(dict(id=cid, file=rel, lang=lang, voice=voice, rate=rate, truth=truth, names=names, noisy=noisy, dur=round(dur, 2)))
    for rel, voice, rate, text in VOICE:
        wav = os.path.join(HERE, rel)
        if FORCE or not os.path.exists(wav):
            say_wav(voice, rate, text, wav)
            write(wav, pad(read(wav)))
    json.dump(items, open(os.path.join(HERE, "manifest.json"), "w"), ensure_ascii=False, indent=1)
    json.dump(DICTIONARY, open(os.path.join(HERE, "dictionary.json"), "w"), ensure_ascii=False, indent=1)
    durs = [i["dur"] for i in items]
    print(f"{len(items)} Erkennungs-Clips, {sum(durs):.0f} s gesamt, kuerzester {min(durs)} s, laengster {max(durs)} s")
    for rel, *_ in VOICE:
        print(f"  {rel}: {len(read(os.path.join(HERE, rel))) / 16000:.1f} s")


if __name__ == "__main__":
    main()
