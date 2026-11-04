# Správa serverů KIT – migrace PHP 8.0 → PHP 8.4

Skripty pro konzervativní migraci Apache `mod_php` na **PHP 8.4.27 nebo vyšší** na **Ubuntu 24.04 (Noble)**. Cílem je připravit jednotný postup pro servery podobné `ete2ae` a `ete30e`.

> ⚠️ Produkční zásah: před použitím je nutná záloha webů a databází / snapshot virtuálního serveru a servisní okno. Úspěšný restart Apache **není** důkazem kompatibility aplikace s PHP 8.4.

## Pro jaké servery je nástroj určen

- Ubuntu **24.04**, běžící Apache s **MPM prefork** a právě jedním aktivním `mod_php` řady PHP 7.x nebo 8.0–8.3.
- Záměrně **odmítá** konfigurace PHP-FPM, `proxy_fcgi` a jiné distribuce; **není** určen pro AlmaLinux, nginx nebo kontejnery.
- Zjistí instalované balíčky PHP a pokusí se nainstalovat odpovídající balíčky `php8.4-*` včetně Apache modulu.
- Přidá `ppa:ondrej/php` pouze pokud není nakonfigurováno, ověří dostupnost opravené verze **alespoň 8.4.27** a simuluje APT bez odstraňování balíčků.
- Zálohuje `/etc/php` a `/etc/apache2` do `/var/backups/php84-migrator/`; uchovává předchozí handler a CLI alternativu pro rollback.
- Přenese pouze několik explicitních direktiv `php.ini`; ostatní vlastní nastavení je třeba porovnat a doplnit ručně.
- Staré balíčky PHP **neodstraňuje**, aby byl možný návrat.

## Jediný příkaz pro další server

Na **administrátorském počítači**, který má SSH přístup k cílovým serverům a přístup k tomuto **soukromému GitHub repozitáři**, si repozitář jednou naklonuj:

```bash
git clone git@github.com:vaclavlohr/sprava-serveru-kit.git
cd sprava-serveru-kit
```

Pak stačí jeden příkaz pro server (z kořene repozitáře):

```bash
./php84-migrator/deploy.sh admin@ete30e --check
./php84-migrator/deploy.sh admin@ete30e --run
```

`admin@ete30e` nahraď skutečným SSH účtem se `sudo` oprávněním; lze použít i `root@ete30e`, je-li jeho SSH přístup povolen. `--run` vždy požaduje ruční potvrzení **MIGRATE**. Přenos probíhá přes SSH a kontroluje se SHA-256. **GitHub token ani klíč se na cílový server nepřenáší.** Pozdější spuštění na dalších serverech je stejné, pouze s jiným cílem.

**Důležité:** před každou sérií nasazení použij zkontrolovaný commit, ideálně konkrétní tag/SHA, a neměň ho během série. Nepoužívej `curl | bash` z privátního GitHubu ani token ve veřejném URL.

## Lokální použití na serveru

Pokud jsi skript přenesl na server jinou ověřenou cestou:

```bash
sudo bash php84-migrate.sh --check
sudo bash php84-migrate.sh --run
sudo bash php84-migrate.sh --status
sudo bash php84-migrate.sh --rollback
```

- `--check`: čtecí diagnostika (výchozí režim)
- `--run`: záloha, kontrola APT, instalace a přepnutí Apache
- `--status`: stav PHP a Apache
- `--rollback`: vrátí předchozí Apache PHP modul a CLI alternativu po potvrzení `ROLLBACK`

## Kontrola po migraci

Ověř `php8.4 -v`, `apache2ctl -M`, `systemctl is-active apache2`, vhosty přes HTTPS, přihlášení, práci s DB, formuláře, cron a chybové logy Apache. Zkontroluj také kompatibilitu aplikací, extensions a případné vlastní změny `php.ini`/`.htaccess`.

Při selhání instalace nebo přepnutí se skript **pokusí** vrátit původní Apache modul; tento rollback **není atomický**, nevrací aktualizované balíčky ani obsah databází. Ruční `--rollback` také nevrací balíčky, `.ini` ani aplikační data. Proto je nutný snapshot a záloha.

## Bezpečnost

Repozitář je **soukromý**. Nevkládej do něj přístupové tokeny, hesla, výpisy konfigurací s tajnými údaji ani archivní zálohy serverů. Script se musí spouštět až po kontrole a v servisním okně. Po úspěšném ověření webových aplikací lze staré PHP odebrat samostatně.