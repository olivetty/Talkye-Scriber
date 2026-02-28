# Test Script — Etalon pentru Talkye Meet

Citeste textul de mai jos in romana, la viteza normala de conversatie.
Rezultatul asteptat: traducere fluenta in engleza, fara pauze mari intre propozitii.


## Textul de test (Romanian)

> Buna ziua, ma numesc Oliver si lucrez ca programator de cinci ani.
> Saptamana trecuta am cumparat o casa noua in centrul orasului.
> A fost un proces destul de complicat, cu multe acte si semnaturi.
> Dar pana la urma totul a mers bine si sunt foarte multumit de rezultat.
> Acum trebuie sa mut toate lucrurile din apartamentul vechi.


## Ce verificam

| # | Criteriu | OK daca |
|---|----------|---------|
| 1 | Prima traducere apare | sub 4s de la inceputul vorbirii |
| 2 | Gap intre propozitii | sub 1s (nu se aude pauza lunga) |
| 3 | Audio nu se taie | ultimul cuvant din fiecare propozitie se aude complet |
| 4 | Nu exista ecou | fiecare cuvant se aude o singura data |
| 5 | STT acuratete | transcrierea romana e corecta (check log) |
| 6 | Traducere coerenta | engleza suna natural, nu literal |
| 7 | Fara stall | Parakeet nu se blocheaza (heartbeat in log) |
| 8 | Fara drain timeout | log-ul NU contine "drain timeout" |


## Traducere asteptata (aproximativ)

> Hello, my name is Oliver and I've been working as a programmer for five years.
> Last week I bought a new house in the city center.
> It was a pretty complicated process, with a lot of paperwork and signatures.
> But in the end everything went well and I'm very happy with the result.
> Now I need to move all my things from the old apartment.


## Cum rulezi

```bash
talkye-cli
# sau
cd ~/Code/talkye-meet/core && RUST_LOG=info cargo run --release 2>&1 | tee /tmp/talkye.log
```

Dupa test, verifica log-ul:
```bash
# Drain timeouts (trebuie sa fie 0)
grep "drain timeout" /tmp/talkye.log

# Fluxul de mesaje TTS
grep "\[TTS\]" /tmp/talkye.log

# STT flush-uri
grep "\[ACCUM\]" /tmp/talkye.log
```
