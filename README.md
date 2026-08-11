# SGG — Instalación y operación

Sistema de Gestión de Geriátrico. Este repo contiene lo mínimo para
**instalar** y **operar** una instancia SGG en una residencia. El código
fuente no vive acá.

## Requisitos

- Ubuntu 22.04+ o Debian 12+ sobre **VM** (Proxmox/KVM, Hyper-V, VMware) o cloud minimal.
- 2 vCPU, 4 GB RAM, 40 GB disco.
- Acceso `sudo` / `root`.
- Un **PAT classic** de GitHub con scope `read:packages` (ver abajo).

> **CT / LXC de Proxmox no es el camino soportado.** Docker adentro de LXC no está
> soportado upstream y la stack falla al montar el volumen de Postgres
> (`operation not permitted`). `install.sh` detecta el container y aborta antes de pedir el
> PAT. Si es un CT **privilegiado** con `--features nesting=1,keyctl=1` y sabés lo que
> hacés, forzalo con `SGG_ALLOW_LXC=1 bash install.sh` — pero el instalador igual corre un
> probe funcional de Docker que **no** se puede saltear: si el kernel no puede montar
> volúmenes, aborta igual. Ante la duda, usá una VM: no requiere ningún tweak.

## Instalación (one-liner)

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/NANDI-Services/SGG-releases/main/install.sh)"
```

El script pide el PAT una vez, genera todos los secrets, levanta la stack
e imprime las credenciales del admin **una sola vez** al final. Guardalas.

## Acceso a la app

Terminada la instalación, SGG escucha en la IP del servidor dentro de la LAN:

| Qué              | URL                                    |
| ---------------- | -------------------------------------- |
| Web              | `http://<IP-DEL-SERVIDOR>:3000`        |
| Health de la API | `http://<IP-DEL-SERVIDOR>:3001/health` |

El paso `7/9 Puertos` del instalador imprime esa IP ya resuelta. Si perdiste el output de
la consola, quedó en el log: `grep 'Web:' /opt/sgg/install.log`. Para averiguarla a mano,
`hostname -I` en el servidor.

Ubuntu y Debian vienen con UFW inactivo por default, así que normalmente no hace falta
abrir nada. Si lo activaste: `sudo ufw allow 3000/tcp && sudo ufw allow 3001/tcp`.

### Cuánto dura la sesión

**24 horas de inactividad.** Quien usa el sistema todos los días no vuelve a ver la
pantalla de login; una máquina que queda abierta y sin usar pide credenciales al día
siguiente. Está pensado para terminales compartidas: es el tiempo que alguien podría
volver a un equipo ajeno y seguir dentro de la historia clínica.

El límite lo aplica el sistema, no el archivo de configuración, así que vale también en
instalaciones que vienen de versiones anteriores. Si tu operación necesita sesiones más
largas, se habilita explícitamente en `/opt/sgg/.env`:

```bash
SGG_ALLOW_LONG_SESSIONS="true"
REFRESH_TOKEN_EXPIRES_IN_DAYS="7"   # el valor pasa a respetarse tal cual
```

y después `cd /opt/sgg && docker compose up -d api`.

### La primera vez que entra un usuario nuevo

Todo usuario recién creado —incluido el administrador que imprime el instalador— tiene
que cambiar su contraseña antes de poder hacer cualquier otra cosa. La pantalla aparece
sola al entrar y no se puede saltear: el bloqueo está en el servidor, no sólo en la
interfaz. Si alguien reporta que "no le anda nada" apenas entra, es esto.

## Cómo generar el PAT (5 min)

El PAT lo genera **NANDI Services** (no el operador de la residencia). El
equipo NANDI lo entrega en el kick-off de la instalación:

1. Abrir https://github.com/settings/tokens/new (tokens **classic**, NO
   fine-grained — los fine-grained no exponen scope Packages para orgs).
2. **Note**: `sgg-<nombre-de-la-residencia>-pull` (trazable por residencia).
3. **Expiration**: **No expiration** — la revocación es manual y controlada
   por NANDI vía UI de GitHub, no por vencimiento automático.
4. **Scopes**: marcar solamente `read:packages`. Nada más.
5. Click **Generate token**. Copiar el string `ghp_...`.
6. Guardar en el vault del equipo NANDI (1Password/Bitwarden) bajo la
   entrada de esa residencia.
7. Pegarlo cuando `install.sh` lo pida en la máquina del cliente.

Después de la instalación, Docker guarda el PAT en `/root/.docker/config.json`.
**El operador NO necesita el PAT de nuevo** ni siquiera para `sgg update`.

## Revocar el acceso de una residencia (kill switch NANDI)

Cuando termina la relación comercial con una residencia:

1. Abrir https://github.com/settings/tokens (con la cuenta que emitió el PAT).
2. Buscar el token `sgg-<residencia>-pull` y revocarlo.
3. Efecto inmediato:
   - `sgg update` en esa residencia falla con `denied: authentication required`.
   - La instalación **sigue funcionando** en la versión pinneada en `.env`
     — no hay corte de servicio, sólo pierde la capacidad de recibir updates.
4. Si eventualmente hay que restablecer acceso, generar un PAT nuevo y en
   la máquina del cliente:
   ```
   echo <nuevo-pat> | sudo docker login ghcr.io -u nandi-services --password-stdin
   ```

## Comandos diarios (`sgg`)

| Comando                                     | Qué hace                                                                                                                |
| ------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `sgg update [--force] [version]`            | Self-update de `sgg`/compose + bump `SGG_VERSION` + pull + up. `--force` limpia el veto de una versión que falló antes. |
| `sgg logs [servicio]`                       | Tail de logs. Sin arg → todos.                                                                                          |
| `sgg doctor`                                | Health HTTP + profundo (`/health/deep`) + disco + `pgbackrest info` + último rollback.                                  |
| `sgg backup-now`                            | Backup **incremental** manual (rápido).                                                                                 |
| `sgg backup-full`                           | Backup **full** manual (el cron ya lo hace semanal).                                                                    |
| `sgg restore-pitr "YYYY-MM-DD HH:MM:SS+TZ"` | Restaura a punto-en-el-tiempo. **Destructivo**. `--force` opcional.                                                     |
| `sgg status`                                | `docker compose ps`.                                                                                                    |
| `sgg version`                               | Versión pinneada en `.env`.                                                                                             |

## Actualizar a una versión nueva

```bash
sudo sgg update 0.1.2
```

Persiste `SGG_VERSION=0.1.2` en `/opt/sgg/.env`, baja las imágenes y recrea
los servicios. Sin argumento, respeta el tag actual y solo re-pullea +
recrea. Con versión, primero se **auto-actualiza**: baja `sgg`,
`docker-compose.yaml` y `.env.example` del release objetivo, verifica
`SHA256SUMS` y mergea variables nuevas al `.env` sin pisar valores.

## Actualización automática (desatendida)

Desde v0.2.0 las instancias se actualizan solas: un agente (`sgg-agent`,
systemd timer cada 5 min) consulta a la API, aplica los updates en la
ventana de mantenimiento (`SGG_UPDATE_WINDOW`, default `03:00-05:00`), hace
backup incremental antes, y si el health check falla revierte con PITR al
instante previo. Detalle completo: `docs/plans/autoupdate-plan.md` (repo
privado).

- **Canal** (`SGG_UPDATE_CHANNEL`): `patch` (default) | `minor` | `off`.
  `off` desactiva el auto-update; el aviso en la web queda informativo.
- **Logs del agente**: `journalctl -u sgg-agent`. Historial local:
  `/opt/sgg/state/journal.ndjson`.
- **Una versión que falló queda vetada** y no se reintenta sola;
  `sudo sgg update --force <version>` la des-veta y aplica a mano.

### Migrar una instalación existente (una sola vez)

Instalaciones anteriores a v0.2.0 no tienen el agente ni el self-update.
Una única sesión SSH lo resuelve:

```bash
curl -fsSL https://raw.githubusercontent.com/NANDI-Services/SGG-releases/main/migrate-to-autoupdate.sh | sudo bash
sudo sgg update <version>
```

Es la última vez que hace falta SSH para actualizar.

## Restaurar a un punto anterior

```bash
sudo sgg restore-pitr "2026-07-25 14:30:00+00"
# Confirmá con 'yes'. La operación:
#   1. Para api/web/migrations
#   2. Para db
#   3. Corre pgbackrest --type=time --target=... --delta restore
#   4. Rearranca db (recovery aplica WAL hasta el timestamp)
#   5. Rearranca api/web
```

**Precondiciones**: al menos un full backup previo + WAL archives cubriendo
el timestamp. `sgg doctor` muestra qué hay.

## Backups — dónde vive todo

- **WAL archives + full backups**: volumen Docker `sgg_pgbackrest`.
  Cifrados AES-256 con `PGBACKREST_REPO_CIPHER_PASS` (guardada en `.env`).
- **Retención**: 2 full + WAL de las últimas ~2 semanas (configurable).
- **Off-site**: NO automatizado en esta versión. Copiar el volumen
  periódicamente a otra máquina/S3 con `docker run --rm -v sgg_pgbackrest:/src -v /backup:/dst alpine tar czf /dst/pgbackrest-$(date +%F).tar.gz -C /src .`

**Importante**: si perdés `PGBACKREST_REPO_CIPHER_PASS`, los backups no
sirven. Guardá copia del `.env` (o al menos esa variable) fuera de la máquina.

## Troubleshooting

- **`install.sh` aborta con `Entorno no soportado`**: estás sobre un CT/LXC, no una VM.
  Ver la nota en Requisitos. La instalación se corta antes de pedir el PAT y antes de
  generar secrets, así que no queda estado a medias: creá una VM y volvé a correr el
  one-liner.
- **`install.sh` aborta con `Docker no es funcional acá`**: el probe levantó un container
  con un volumen montado y falló. En un CT Proxmox significa que faltan
  `--features nesting=1,keyctl=1` o que el CT es unprivileged. En una VM, apunta a un
  daemon de Docker roto: `systemctl status docker` y `docker info`.
- **`sgg update` falla con `denied` o `unauthorized`**: PAT venció o fue
  revocado. Regenerar y volver a `docker login ghcr.io`.
- **`sgg doctor` dice `db down`**: `sgg logs db` para ver el motivo.
  Común: disco lleno (`df -h`), `PGBACKREST_REPO_CIPHER_PASS` cambiada
  vs. lo que espera el repo pgBackRest existente.
- **Web carga pero no llega al API**: el web hace fetch same-origin a `/api/*`
  y Next lo proxea al container `api`. Si `sgg doctor` da los dos servicios
  healthy pero el login sigue fallando, `sgg logs web` va a mostrar el error
  de proxy. Cambiar de hostname no requiere rebuild — la imagen web es
  cliente-agnóstica.

## Desinstalar

```bash
cd /opt/sgg
docker compose down -v   # -v borra los volúmenes (Y LOS DATOS)
rm -rf /opt/sgg
rm /usr/local/bin/sgg
```

## Licencia

Todos los derechos reservados © NANDI Services. Uso permitido exclusivamente
a residencias con contrato vigente. El código fuente de SGG NO se distribuye
acá — es privado, se sirve como imágenes de contenedor en el registry
privado de la organización.
