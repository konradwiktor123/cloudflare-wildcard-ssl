#!/usr/bin/env bash
#
# ssl-cert.sh — certyfikat Let's Encrypt typu wildcard (example.com + *.example.com)
# z weryfikacją DNS przez Cloudflare. Działa na macOS i Linuksie (wymaga python3 i openssl).
#
# Użycie:
#   ./ssl-cert.sh                 # zapyta o domenę, serwer WWW, e-mail i token Cloudflare
#   ./ssl-cert.sh example.com     # domena podana od razu
#
# Serwer WWW (nginx / apache / brak): skrypt wypisze gotowy fragment konfiguracji,
# a jeśli ten serwer działa na tej maszynie (Linux, root) — przeładuje go po wydaniu
# certyfikatu i przy każdym odnowieniu. Przy wyborze "brak" pliki certyfikatu są
# kopiowane do folderu domowego użytkownika: ~/ssl/<domena>/
#
# Opcje:
#   --force       odnów teraz, nawet jeśli certyfikat jest jeszcze długo ważny
#   --staging     testowy serwer Let's Encrypt (bez limitów; certyfikat nieważny w przeglądarkach)
#   --agree-tos   nie pytaj o akceptację regulaminu Let's Encrypt (akceptujesz go z góry)
#   --server=X    serwer WWW bez pytania: nginx, apache albo none
#
# Zmienne środowiskowe (opcjonalne, np. do automatyzacji):
#   CLOUDFLARE_API_TOKEN   token Cloudflare — wtedy skrypt o niego nie pyta
#   LE_EMAIL               e-mail do powiadomień Let's Encrypt ("-" = bez e-maila)
#   LE_DIR                 katalog roboczy certbota (domyślnie ~/.letsencrypt-cloudflare)
#
# Token Cloudflare: My Profile → API Tokens → Create Token → szablon "Edit zone DNS",
# ograniczony do jednej domeny. Nie używaj Global API Key.
# Token nie jest nigdzie zapisywany na stałe — trafia do pliku tymczasowego,
# który jest kasowany po zakończeniu skryptu.
#
set -euo pipefail

DOMAIN=""
EXTRA=()
AGREE=0
SERVER=""
for arg in "$@"; do
    case "$arg" in
        --force)     EXTRA+=(--force-renewal) ;;
        --staging)   EXTRA+=(--staging) ;;
        --agree-tos) AGREE=1 ;;
        --server=*)  SERVER="${arg#--server=}" ;;
        -h|--help)   sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)          echo "Nieznana opcja: $arg (pomoc: $0 --help)"; exit 1 ;;
        *)           DOMAIN="$arg" ;;
    esac
done

LE_DIR="${LE_DIR:-$HOME/.letsencrypt-cloudflare}"
umask 077
mkdir -p "$LE_DIR"

# --- domena --------------------------------------------------------------
if [ -z "$DOMAIN" ]; then
    read -rp "Domena (np. example.com): " DOMAIN || true
fi
DOMAIN="${DOMAIN#\*.}"                          # "*.example.com" -> "example.com"
DOMAIN="$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
if ! printf '%s' "$DOMAIN" | grep -Eq '^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$'; then
    echo "Nieprawidłowa domena: '$DOMAIN'"; exit 1
fi

# --- serwer WWW -----------------------------------------------------------
if [ -z "$SERVER" ]; then
    echo "Serwer WWW, dla którego jest certyfikat:"
    echo "  1) nginx"
    echo "  2) apache"
    echo "  3) żaden — zapisz pliki w folderze domowym (~/ssl/<domena>/)"
    read -rp "Wybór [1-3]: " choice || true
    case "$choice" in 1) SERVER=nginx ;; 2) SERVER=apache ;; 3) SERVER=none ;; *) SERVER="" ;; esac
fi
case "$SERVER" in
    nginx|apache|none) ;;
    *) echo "Nieprawidłowy wybór serwera WWW: '$SERVER' (dozwolone: nginx, apache, none)"; exit 1 ;;
esac

# Usługa do przeładowania: tylko gdy działa lokalnie i mamy uprawnienia roota.
SERVICE=""
if [ "$SERVER" != none ] && [ "$(id -u)" = 0 ] && command -v systemctl >/dev/null 2>&1; then
    if [ "$SERVER" = nginx ]; then
        systemctl is-active --quiet nginx && SERVICE=nginx
    else
        for s in apache2 httpd; do systemctl is-active --quiet "$s" && { SERVICE="$s"; break; }; done
    fi
fi
if [ -n "$SERVICE" ]; then
    if [ "$SERVER" = nginx ]; then TEST="nginx -t"; else TEST="apachectl configtest"; fi
    # Przeładowanie tylko przy poprawnej konfiguracji — zepsuty config nie wyłączy strony.
    EXTRA+=(--deploy-hook "$TEST && systemctl reload $SERVICE")
fi

# --- token Cloudflare ----------------------------------------------------
TOKEN="${CLOUDFLARE_API_TOKEN:-}"
if [ -z "$TOKEN" ]; then
    read -rsp "Token API Cloudflare (Edit zone DNS, wpisywanie niewidoczne): " TOKEN || true; echo
fi
[ -n "$TOKEN" ] || { echo "Nie podano tokenu."; exit 1; }

echo "==> Sprawdzam token w Cloudflare"
CF_ZONE=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
    | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: print("ERR:brak odpowiedzi"); sys.exit()
if not d.get("success"): print("ERR:" + "; ".join(e.get("message","") for e in d.get("errors",[]))); sys.exit()
print("OK" if d.get("result") else "NOZONE")')
case "$CF_ZONE" in
    OK)     echo "    token działa, strefa $DOMAIN dostępna" ;;
    NOZONE) echo "!! Token działa, ale nie ma dostępu do strefy $DOMAIN w Cloudflare."; exit 1 ;;
    *)      echo "!! Cloudflare odrzucił token: ${CF_ZONE#ERR:}"
            echo "   Użyj tokenu API (szablon \"Edit zone DNS\"), nie Global API Key."; exit 1 ;;
esac

# --- e-mail i regulamin --------------------------------------------------
EMAIL="${LE_EMAIL:-}"
if [ -z "$EMAIL" ]; then
    read -rp "E-mail do powiadomień o wygasaniu (Enter = bez e-maila): " EMAIL || true
fi
[ "$EMAIL" = "-" ] && EMAIL=""

if [ "$AGREE" != 1 ]; then
    echo "Let's Encrypt wymaga akceptacji regulaminu: https://letsencrypt.org/repository/"
    read -rp "Akceptujesz regulamin Let's Encrypt? [t/N] " ans || true
    case "$ans" in t|T|tak|y|Y|yes) ;; *) echo "Przerwano."; exit 1 ;; esac
fi

# --- certbot -------------------------------------------------------------
CERTBOT="$LE_DIR/venv/bin/certbot"
if [ ! -x "$CERTBOT" ]; then
    echo "==> Instaluję certbota z wtyczką Cloudflare (jednorazowo, do $LE_DIR/venv)"
    python3 -m venv "$LE_DIR/venv"
    "$LE_DIR/venv/bin/pip" install -q --upgrade pip
    "$LE_DIR/venv/bin/pip" install -q certbot certbot-dns-cloudflare
fi

CREDS="$(mktemp "$LE_DIR/cloudflare.XXXXXX")"
trap 'rm -f "$CREDS"' EXIT
printf 'dns_cloudflare_api_token = %s\n' "$TOKEN" > "$CREDS"
unset TOKEN CLOUDFLARE_API_TOKEN

if [ -n "$EMAIL" ]; then ACCOUNT=(-m "$EMAIL"); else ACCOUNT=(--register-unsafely-without-email); fi

# --keep-until-expiring: istniejący certyfikat odnawiany jest dopiero ~30 dni przed wygaśnięciem.
echo "==> Certyfikat dla: $DOMAIN, *.$DOMAIN"
"$CERTBOT" certonly --non-interactive --agree-tos "${ACCOUNT[@]}" \
    --dns-cloudflare --dns-cloudflare-credentials "$CREDS" \
    --dns-cloudflare-propagation-seconds 30 \
    --keep-until-expiring --cert-name "$DOMAIN" \
    -d "$DOMAIN" -d "*.$DOMAIN" \
    --config-dir "$LE_DIR/config" --work-dir "$LE_DIR/work" --logs-dir "$LE_DIR/logs" \
    ${EXTRA[@]+"${EXTRA[@]}"} 2>&1 | grep -vE "^ \* Donating|^If you like Certbot|^- - -|renewal-setup|Certbot can automatically renew" || true

LIVE="$LE_DIR/config/live/$DOMAIN"
if [ ! -f "$LIVE/fullchain.pem" ]; then
    echo "!! Nie udało się wygenerować certyfikatu — szczegóły: $LE_DIR/logs/letsencrypt.log"; exit 1
fi

# Bez serwera WWW: kopia plików do folderu domowego użytkownika (przy sudo — tego,
# który uruchomił sudo, a nie roota). Kopiujemy prawdziwe pliki, nie dowiązania.
if [ "$SERVER" = none ]; then
    OWNER="${SUDO_USER:-$(id -un)}"
    OWNER_HOME="$(eval echo "~$OWNER")"
    OUT="$OWNER_HOME/ssl/$DOMAIN"
    mkdir -p "$OUT"
    for f in fullchain.pem privkey.pem cert.pem chain.pem; do
        cp -L "$LIVE/$f" "$OUT/$f"
    done
    chmod 700 "$OWNER_HOME/ssl" "$OUT"
    chmod 600 "$OUT"/*.pem
    [ "$OWNER" != "$(id -un)" ] && chown -R "$OWNER": "$OWNER_HOME/ssl"
    LIVE="$OUT"
fi

echo
echo "==> Gotowe"
openssl x509 -noout -subject -enddate -in "$LIVE/cert.pem" | sed 's/^/    /'
if [ "$SERVER" = none ]; then
    echo "    Pliki zapisane w: $LIVE/"
    echo "      fullchain.pem  certyfikat z łańcuchem (to podajesz serwerowi WWW)"
    echo "      privkey.pem    klucz prywatny — nikomu go nie udostępniaj"
    echo "      cert.pem       sam certyfikat domeny"
    echo "      chain.pem      certyfikaty pośrednie"
else
    echo "    Certyfikat z łańcuchem (ssl_certificate):     $LIVE/fullchain.pem"
    echo "    Klucz prywatny        (ssl_certificate_key): $LIVE/privkey.pem"
fi
echo "    Odnowienie: uruchom skrypt ponownie przed datą wygaśnięcia (co ~60–90 dni)."

case "$SERVER" in
    nginx)
        echo
        echo "==> nginx — dodaj do bloku server { ... } swojej strony:"
        echo "    listen 443 ssl;"
        echo "    listen [::]:443 ssl;"
        echo "    server_name $DOMAIN *.$DOMAIN;"
        echo "    ssl_certificate     $LIVE/fullchain.pem;"
        echo "    ssl_certificate_key $LIVE/privkey.pem;"
        echo "    ssl_protocols TLSv1.2 TLSv1.3;"
        echo "  Potem: sudo nginx -t && sudo systemctl reload nginx"
        ;;
    apache)
        echo
        echo "==> Apache — w <VirtualHost *:443> swojej strony (wymaga: sudo a2enmod ssl):"
        echo "    ServerName $DOMAIN"
        echo "    ServerAlias *.$DOMAIN"
        echo "    SSLEngine on"
        echo "    SSLCertificateFile    $LIVE/fullchain.pem"
        echo "    SSLCertificateKeyFile $LIVE/privkey.pem"
        echo "  Potem: sudo apachectl configtest && sudo systemctl reload apache2   (lub httpd)"
        ;;
esac

if [ -n "$SERVICE" ]; then
    if [ "$SERVER" = nginx ]; then TEST="nginx -t"; else TEST="apachectl configtest"; fi
    if $TEST >/dev/null 2>&1; then
        systemctl reload "$SERVICE" && echo "==> Przeładowano $SERVICE (przy odnowieniach certbot zrobi to sam)."
    else
        echo "!! Konfiguracja $SERVICE ma błędy — nie przeładowuję. Sprawdź: $TEST"
    fi
elif [ "$SERVER" != none ]; then
    echo "  ($SERVER nie działa na tej maszynie jako usługa albo skrypt nie ma roota — przeładuj go ręcznie.)"
fi
