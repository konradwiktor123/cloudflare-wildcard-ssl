# cloudflare-wildcard-ssl

Jeden skrypt w Bashu, który generuje i odnawia darmowy certyfikat **Let's Encrypt typu wildcard** (`example.com` + `*.example.com`) z weryfikacją DNS przez **Cloudflare**.

Wildcard wymaga weryfikacji DNS (rekordu TXT), więc zwykłe `certbot --nginx` tu nie wystarczy. Skrypt robi to za ciebie przez API Cloudflare: sam dodaje rekord, czeka na weryfikację i go usuwa.

## Co robi

- Pyta o **domenę**, **serwer WWW** (nginx, Apache albo żaden), **token Cloudflare** i **e-mail**.
- Od razu sprawdza token w Cloudflare, zanim cokolwiek zacznie.
- Przy pierwszym uruchomieniu sam instaluje `certbot` z wtyczką `certbot-dns-cloudflare` w osobnym środowisku Pythona, więc niczego nie instaluje w systemie.
- Wydaje certyfikat albo odnawia istniejący. Odnowienie następuje dopiero około 30 dni przed wygaśnięciem, więc skrypt można uruchamiać bezpiecznie w dowolnym momencie.
- Wypisuje gotowy fragment konfiguracji dla **nginx** albo **Apache**.
- Przy wyborze **„żaden”** zapisuje pliki certyfikatu w folderze domowym: `~/ssl/<domena>/` (`fullchain.pem`, `privkey.pem`, `cert.pem`, `chain.pem`). Przy `sudo` trafiają do folderu użytkownika, który uruchomił `sudo`, a nie roota.
- Jeśli wybrany serwer działa na tej maszynie (Linux, root), **przeładowuje go** po wydaniu i przy każdym odnowieniu, ale tylko wtedy, gdy test konfiguracji przejdzie.
- **Nie zapisuje tokenu na stałe.** Token trafia do pliku tymczasowego, kasowanego po zakończeniu skryptu.

## Wymagania

- macOS albo Linux
- `bash`, `python3` (z modułem `venv`), `curl`, `openssl`
- Domena w Cloudflare (DNS zarządzany przez Cloudflare)

Na Debianie i Ubuntu brakujące pakiety zainstalujesz tak:

```bash
sudo apt install python3 python3-venv curl openssl
```

## Token Cloudflare

Użyj **tokenu API** z uprawnieniem tylko do DNS jednej domeny. **Nie używaj Global API Key**, bo daje pełny dostęp do całego konta.

1. Cloudflare: **My Profile → API Tokens → Create Token**.
2. Szablon **Edit zone DNS**.
3. **Zone Resources**: Include → Specific zone → twoja domena.
4. Utwórz token i skopiuj go (40 znaków).

## Użycie

```bash
chmod +x ssl-cert.sh
./ssl-cert.sh
```

Przykład:

```
Domena (np. example.com): example.com
Serwer WWW, dla którego jest certyfikat:
  1) nginx
  2) apache
  3) żaden — zapisz pliki w folderze domowym (~/ssl/<domena>/)
Wybór [1-3]: 1
Token API Cloudflare (Edit zone DNS, wpisywanie niewidoczne):
==> Sprawdzam token w Cloudflare
    token działa, strefa example.com dostępna
E-mail do powiadomień o wygasaniu (Enter = bez e-maila): ja@example.com
Akceptujesz regulamin Let's Encrypt? [t/N] t
==> Certyfikat dla: example.com, *.example.com
...
==> Gotowe
    Certyfikat z łańcuchem (nginx: ssl_certificate):   ~/.letsencrypt-cloudflare/config/live/example.com/fullchain.pem
    Klucz prywatny        (nginx: ssl_certificate_key): ~/.letsencrypt-cloudflare/config/live/example.com/privkey.pem
```

Uruchamiany z `sudo` na serwerze używa katalogu domowego roota, czyli `/root/.letsencrypt-cloudflare`.

### Opcje

| Opcja | Działanie |
|---|---|
| `example.com` | domena podana od razu (może być też `*.example.com`) |
| `--server=nginx\|apache\|none` | serwer WWW bez pytania |
| `--agree-tos` | akceptacja regulaminu Let's Encrypt bez pytania |
| `--force` | odnów teraz, nawet jeśli certyfikat jest jeszcze długo ważny |
| `--staging` | testowy serwer Let's Encrypt, bez limitów, ale certyfikat nie działa w przeglądarkach (tylko do testów nowej domeny) |
| `-h`, `--help` | pomoc |

### Zmienne środowiskowe

| Zmienna | Działanie |
|---|---|
| `CLOUDFLARE_API_TOKEN` | token Cloudflare, skrypt nie pyta o niego |
| `LE_EMAIL` | e-mail do powiadomień, `-` oznacza brak e-maila |
| `LE_DIR` | katalog roboczy certbota, domyślnie `~/.letsencrypt-cloudflare` |

## Automatyczne odnawianie (cron)

Certyfikaty Let's Encrypt są ważne 90 dni. Na serwerze możesz uruchamiać skrypt raz w tygodniu, a certyfikat odnowi się sam, gdy zbliży się data wygaśnięcia:

```bash
sudo crontab -e
```

```cron
0 4 * * 1  CLOUDFLARE_API_TOKEN=twoj_token LE_EMAIL=ja@example.com /opt/ssl-cert.sh example.com --server=nginx --agree-tos >> /var/log/ssl-cert.log 2>&1
```

Token w crontabie jest zapisany zwykłym tekstem, dlatego użyj tokenu ograniczonego do jednej domeny.

## Konfiguracja serwera

**nginx**, w bloku `server { ... }`:

```nginx
listen 443 ssl;
listen [::]:443 ssl;
server_name example.com *.example.com;
ssl_certificate     /root/.letsencrypt-cloudflare/config/live/example.com/fullchain.pem;
ssl_certificate_key /root/.letsencrypt-cloudflare/config/live/example.com/privkey.pem;
ssl_protocols TLSv1.2 TLSv1.3;
```

**Apache**, w `<VirtualHost *:443>` (wymaga `sudo a2enmod ssl`):

```apache
ServerName example.com
ServerAlias *.example.com
SSLEngine on
SSLCertificateFile    /root/.letsencrypt-cloudflare/config/live/example.com/fullchain.pem
SSLCertificateKeyFile /root/.letsencrypt-cloudflare/config/live/example.com/privkey.pem
```

Skrypt nie zmienia plików konfiguracyjnych twoich stron. Wypisuje tylko fragment do wklejenia, a przeładowuje serwer wyłącznie po udanym teście konfiguracji.

## Rozwiązywanie problemów

- **„Cloudflare odrzucił token: Invalid request headers”**: to nie jest token API. Najczęściej wklejono Global API Key (37 znaków). Utwórz token według instrukcji wyżej.
- **„Token działa, ale nie ma dostępu do strefy”**: token jest ograniczony do innej domeny albo domena nie jest w tym koncie Cloudflare.
- **Błąd weryfikacji DNS**: sprawdź, czy domena naprawdę używa serwerów nazw Cloudflare. Szczegóły są w `~/.letsencrypt-cloudflare/logs/letsencrypt.log`.
- **„too many certificates already issued”**: przekroczono limity Let's Encrypt. Do testów używaj `--staging`.

## Licencja

[MIT](LICENSE) © 2026 Konrad Wiktor
