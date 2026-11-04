# Správa serverů KIT – migrace PHP 8.0 → PHP 8.4

Skripty pro konzervativní migraci Apache `mod_php` na **PHP 8.4.27 nebo vyšší** na **Ubuntu 22.04 (Jammy) nebo 24.04 (Noble)**. Cílem je připravit jednotný postup pro servery podobné `ete2ae` a `ete30e`.

> ⚠️ Produkční zásah: před použitím je nutná záloha webů a databází / snapshot virtuálního serveru a servisní okno. Úspěšný restart Apache **není** důkazem kompatibility aplikace s PHP 8.4.

## Pro jaké servery je nástroj určen

- Ubuntu **22.04 nebo 24.04**, běžící Apache s **MPM prefork** a právě jedním aktivním `mod_php` řady PHP 7.x nebo 8.0–8.3.
- Záměrně **odmítá** konfigurace PHP-FPM, `proxy_fcgi`, Ubuntu 20.04 a jiné distribuce; **není** určen pro AlmaLinux, nginx nebo kontejnery. Verzi OS kontroluje přes `/etc/os-release`, nikoli podle jádra z `uname -a`.
- Zjistí instalované balíčky PHP a pokusí se nainstalovat odpovídající balíčky `php8.4-*` včetně Apache modulu.
- Přidá `ppa:ondrej/php` pouze pokud není nakonfigurováno, ověří dostupnost opravené verze **alespoň 8.4.27** a simuluje APT bez odstraňování balíčků.
- Zálohuje `/etc/php` a `/etc/apache2` do `/var/backups/php84-migrator/`; uchovává předchozí handler a CLI alternativu pro rollback.
- Přenese pouze několik explicitních direktiv `php.ini`; ostatní vlastní nastavení je třeba porovnat a doplnit ručně.
- Staré balíčky PHP **neodstraňuje**, aby byl možný návrat.

## Ověření verze operačního systému

```bash
cat /etc/os-release | grep -E '^(PRETTY_NAME|VERSION_ID|VERSION_CODENAME)='
```

Jádro `5.15` samo o sobě neprokazuje Ubuntu 22.04: může jít i o jinou verzi Ubuntu s HWE jádrem. Pro automatickou migraci skript povolí pouze Jammy a Noble. Na Ubuntu 20.04 je nutné nejprve naplánovat upgrade OS. PHP 8.4 musí být dostupné v APT pro konkrétní distribuci a skript před instalací ověřuje, že jde alespoň o verzi 8.4.27.

## Stažení a spuštění přímo na serveru (doporučeno)

Pokud jsi již přihlášený na cílovém serveru jako `root` nebo přes `sudo`, nepotřebuješ SSH připojení k GitHubu ani token. Veřejný repozitář stáhneš přes HTTPS:

```bash
git clone https://github.com/vaclavlohr/sprava-serveru-kit.git
cd sprava-serveru-kit
```

Pokud už máš repozitář naklonovaný (například na `ete34e`), místo opakovaného `git clone` aktualizuj pracovní kopii:

```bash
git pull --ff-only
```

Nejprve spusť nezásahovou diagnostiku:

```bash
sudo bash php84-migrator/php84-migrate.sh --check
```

Po kontrole výstupu a zajištění zálohy/snapshotu proveď migraci:

```bash
sudo bash php84-migrator/php84-migrate.sh --run
```

Kontrola stavu a případný návrat:

```bash
sudo bash php84-migrator/php84-migrate.sh --status
sudo bash php84-migrator/php84-migrate.sh --rollback
```

`--run` požaduje potvrzení **MIGRATE**. Před nasazením na další servery doporučujeme používat stejný prověřený commit či tag.

Režimy skriptu:

- `--check`: čtecí diagnostika (výchozí režim)
- `--run`: záloha, kontrola APT, instalace a přepnutí Apache
- `--status`: stav PHP a Apache
- `--rollback`: vrátí předchozí Apache PHP modul a CLI alternativu po potvrzení `ROLLBACK`

## Volitelně: vzdálené nasazení přes SSH

Z administrátorského počítače s naklonovaným repozitářem lze místo lokálního spuštění použít:

```bash
bash php84-migrator/deploy.sh root@ete30e --check
bash php84-migrator/deploy.sh root@ete30e --run
```

Tento postup používá SSH pouze pro spojení s cílovým serverem, nikoliv pro přihlášení ke GitHubu. V případě jiného uživatele musí mít účet příslušná oprávnění `sudo`. Přenos skriptu kontroluje SHA-256.


## Pokud `--check` prošel, ale `--run` hlásí neaktivní mod_php

Ve verzi 1.2.0 mohla kontrola `apache2ctl -M | grep -q` v kombinaci s `set -o pipefail` skončit falešnou chybou kvůli `SIGPIPE`. Od verze **1.2.1** se výpis Apache načítá jednou a vyhodnocuje bez této roury. Na serveru s již naklonovaným repozitářem spusť:

```bash
cd ~/sprava-serveru-kit
git pull --ff-only
sudo bash php84-migrator/php84-migrate.sh --check
sudo bash php84-migrator/php84-migrate.sh --run
```

Jestliže chyba trvá i po aktualizaci, nejprve ověř `apache2ctl -M` a aktivní moduly; neobcházej kontroly úpravou skriptu.

## Kontrola po migraci

Ověř `php8.4 -v`, `apache2ctl -M`, `systemctl is-active apache2`, vhosty přes HTTPS, přihlášení, práci s DB, formuláře, cron a chybové logy Apache. Zkontroluj také kompatibilitu aplikací, extensions a případné vlastní změny `php.ini`/`.htaccess`.

Při selhání instalace nebo přepnutí se skript **pokusí** vrátit původní Apache modul; tento rollback **není atomický**, nevrací aktualizované balíčky ani obsah databází. Ruční `--rollback` také nevrací balíčky, `.ini` ani aplikační data. Proto je nutný snapshot a záloha.

## Bezpečnost

Repozitář je **veřejný**. Nevkládej do něj přístupové tokeny, hesla, výpisy konfigurací s tajnými údaji ani archivní zálohy serverů. Script se musí spouštět až po kontrole a v servisním okně. Po úspěšném ověření webových aplikací lze staré PHP odebrat samostatně.