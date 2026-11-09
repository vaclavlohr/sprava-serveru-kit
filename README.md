# Správa serverů KIT – migrace PHP 8.0 → PHP 8.4

Skripty pro konzervativní migraci Apache `mod_php` na **PHP 8.4.27 nebo vyšší** na **Ubuntu 22.04 (Jammy) nebo 24.04 (Noble)**. Diagnostika nově funguje také na serverech bez běžícího Apache (například `ete50e`) a rozpoznává Nginx, PHP-FPM a PHP CLI; tyto odlišné konfigurace zatím **automaticky nemigruje**.

> ⚠️ Produkční zásah: před použitím je nutná záloha webů a databází / snapshot virtuálního serveru a servisní okno. Úspěšný restart Apache **není** důkazem kompatibility aplikace s PHP 8.4.

## Pro jaké servery je nástroj určen

- Automatický režim `--run`: Ubuntu **22.04 nebo 24.04**, běžící Apache s **MPM prefork** a právě jedním aktivním `mod_php` řady PHP 7.x nebo 8.0–8.3. Režimy `--check` a `--status` lze spustit i bez Apache.
- Záměrně **odmítá** konfigurace PHP-FPM, `proxy_fcgi`, Ubuntu 20.04 a jiné distribuce; **není** určen pro AlmaLinux, nginx nebo kontejnery. Verzi OS kontroluje přes `/etc/os-release`, nikoli podle jádra z `uname -a`.
- Zjistí instalované balíčky PHP a pokusí se nainstalovat odpovídající balíčky `php8.4-*` včetně Apache modulu.
- Ověří skutečnou dostupnost PHP 8.4 v aktivních zdrojích APT; pokud balíček chybí, pokusí se aktivovat `ppa:ondrej/php`, obnoví metadata a kontrolu zopakuje. Vyžaduje opravenou verzi **alespoň 8.4.27** a simuluje APT bez odstraňování balíčků.
- Zálohuje `/etc/php` a `/etc/apache2` do `/var/backups/php84-migrator/`; uchovává předchozí handler a CLI alternativu pro rollback.
- Přenese pouze několik explicitních direktiv `php.ini`; ostatní vlastní nastavení je třeba porovnat a doplnit ručně.
- Staré balíčky PHP **neodstraňuje**, aby byl možný návrat.
- Po úspěšné migraci PHP také vypne MPTCP (`net.mptcp.enabled=0`) za běhu a trvale přes `/etc/sysctl.d/99-zz-kit-disable-mptcp.conf`, pokud jej jádro podporuje. Původní nastavení ukládá pro samostatný návrat.

## Univerzální diagnostika (verze 1.3.0)

`--check` a `--status` už nevyžadují nainstalovaný ani běžící Apache. Vypisují operační systém, PHP CLI, stav Apache a Nginxu, dostupné balíčky a systemd služby PHP-FPM, případné moduly Apache a nakonfigurované virtuální hostitele.

```bash
cd ~/sprava-serveru-kit
git pull --ff-only
sudo bash php84-migrator/php84-migrate.sh --check
```

Pokud Apache neběží, `--check` úspěšně dokončí inventuru a vypíše **NOT ELIGIBLE** pro automatickou migraci `mod_php` – **neznamená to, že server nevyužívá PHP**. Může používat Nginx + PHP-FPM, samostatné FPM, CLI/cron nebo Apache záměrně mimo provoz. Automatické `--run` nadále vyžaduje **běžící Apache s `mod_php`**, aby nedošlo k nechtěnému startu služby nebo přepnutí jiného PHP handleru. Po zjištění skutečné konfigurace lze připravit bezpečnou migraci dané varianty.

## Vypnutí MPTCP (verze 1.4.0)

MPTCP (Multipath TCP) je volitelná funkce linuxového jádra. `net.mptcp.enabled=0` zakáže vytváření nových MPTCP socketů v příslušném síťovém namespace; neodstraňuje podporu TCP a **nenahrazuje bezpečnostní aktualizaci jádra**.

Skript nastavení zobrazuje při `--check` a `--status`, aniž by cokoli měnil. Po **úspěšné** migraci PHP v režimu `--run` MPTCP také vypne. Pokud systém parametr nemá, krok přeskočí s oznámením. U serverů bez Apache, s Nginx/PHP-FPM nebo s již aktualizovaným PHP lze použít samostatný příkaz, který PHP ani webový server nemění:

```bash
cd ~/sprava-serveru-kit
git pull --ff-only
sudo bash php84-migrator/php84-migrate.sh --disable-mptcp
```

Vyžaduje potvrzení `MPTCP`, následně provede `sysctl -w net.mptcp.enabled=0` a vytvoří trvalý soubor `/etc/sysctl.d/99-zz-kit-disable-mptcp.conf`. Původní runtime hodnotu a případný původní soubor uloží do `/var/backups/php84-migrator/mptcp-original/`. Opakované spuštění tuto původní zálohu nepřepíše.

Ověření:

```bash
sysctl net.mptcp.enabled
cat /etc/sysctl.d/99-zz-kit-disable-mptcp.conf
```

Pokud je návrat nutný, obnoví se **pouze MPTCP** (po potvrzení `RESTORE-MPTCP`):

```bash
sudo bash php84-migrator/php84-migrate.sh --restore-mptcp
```

`--rollback` se vztahuje na modul Apache/CLI, **nikoli** na nastavení MPTCP. Při konfliktu s explicitním `net.mptcp.enabled=1` v `/etc/sysctl.conf` skript změnu odmítne. Pokud jiný soubor `sysctl.d` nastavuje stejnou hodnotu později nebo ji mění jiný správce konfigurace, je potřeba ověřit nastavení i po restartu. Omezení je platné pro aktuální síťový namespace; kontejnery mohou používat vlastní.

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

- `--check`: čtecí diagnostika prostředí i bez Apache (výchozí režim)
- `--run`: záloha, kontrola APT, instalace a přepnutí Apache
- `--status`: stav OS, PHP CLI, Apache, Nginxu a PHP-FPM
- `--rollback`: vrátí předchozí Apache PHP modul a CLI alternativu po potvrzení `ROLLBACK`
- `--disable-mptcp`: vypne MPTCP nyní i po restartu (bez zásahu do PHP/Apache)
- `--restore-mptcp`: obnoví uložené původní nastavení MPTCP

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

## PHP 8.4 se nenabízí v APT (Ubuntu 22.04 / 24.04)

Ve verzích před 1.2.2 skript hledal text `ondrej/php` v souborech APT, což mohlo chybně vyhodnotit vypnutý nebo historický zdroj jako aktivní. **Od verze 1.2.2** kontroluje skutečného kandidáta `php8.4-cli`; pokud neexistuje, pokusí se PPA aktivovat a metadata APT znovu načíst.

Na již naklonovaném serveru aktualizuj skript:

```bash
cd ~/sprava-serveru-kit
git pull --ff-only
apt-cache policy php8.4-cli
sudo bash php84-migrator/php84-migrate.sh --run
```

Pokud se kandidát neobjeví ani po pokusu o přidání PPA, skript bezpečně skončí bez instalace PHP. Zkontroluj `apt-cache policy php8.4-cli`, soubory `/etc/apt/sources.list.d/` a případné chyby při `apt-get update`.

## Neočekávané ukončení po `apt-get update` (opraveno v 1.2.3)

Ve verzi 1.2.2 se mohl skript bez zprávy ukončit bezprostředně po aktualizaci indexů APT. Příčinou bylo `awk` s předčasným `exit` v rource pod `set -o pipefail`: `apt-cache` mohl skončit na SIGPIPE (kód 141). Verze **1.2.3** zpracovává celý výstup APT a při neočekávaném selhání vypíše řádek i příkaz.

Pokud migrace skončila před výpisem `APT candidate:` nebo `Installing PHP 8.4`, nedošlo ještě k instalaci balíčků ani k přepnutí Apache. Po aktualizaci pracovní kopie spusť znovu:

```bash
cd ~/sprava-serveru-kit
git pull --ff-only
sudo bash php84-migrator/php84-migrate.sh --run
```

Skript před každým pokusem vytváří novou zálohu konfigurace. Zálohy aplikací a databází/snapshot serveru jsou přesto odpovědností správce.

## Kontrola po migraci

Ověř `php8.4 -v`, `apache2ctl -M`, `systemctl is-active apache2`, vhosty přes HTTPS, přihlášení, práci s DB, formuláře, cron a chybové logy Apache. Zkontroluj také kompatibilitu aplikací, extensions a případné vlastní změny `php.ini`/`.htaccess`.

Při selhání instalace nebo přepnutí se skript **pokusí** vrátit původní Apache modul; tento rollback **není atomický**, nevrací aktualizované balíčky ani obsah databází. Ruční `--rollback` také nevrací balíčky, `.ini` ani aplikační data. Proto je nutný snapshot a záloha.

## Bezpečnost

Repozitář je **veřejný**. Nevkládej do něj přístupové tokeny, hesla, výpisy konfigurací s tajnými údaji ani archivní zálohy serverů. Script se musí spouštět až po kontrole a v servisním okně. Po úspěšném ověření webových aplikací lze staré PHP odebrat samostatně.