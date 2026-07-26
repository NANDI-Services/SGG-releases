# SGG — Instalación y operación

Sistema de Gestión de Geriátrico. Este repo contiene lo mínimo para
**instalar** y **operar** una instancia SGG en una residencia. El código
fuente no vive acá.

## Requisitos

- Ubuntu 22.04+ o Debian 12+ (VM, CT Proxmox, cloud minimal).
- 2 vCPU, 4 GB RAM, 40 GB disco.
- Acceso `sudo` / `root`.
- Un **PAT classic** de GitHub con scope `read:packages` (ver abajo).

## Instalación (one-liner)

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/NANDI-Services/SGG-releases/main/install.sh)"
```

El script pide el PAT una vez, genera todos los secrets, levanta la stack
e imprime las credenciales del admin **una sola vez** al final. Guardalas.

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

| Comando                                  | Qué hace                                                 |
| ---------------------------------------- | -------------------------------------------------------- |
| `sgg update`                             | Baja imágenes nuevas + recrea servicios (~15s downtime). |
| `sgg logs [servicio]`                    | Tail de logs. Sin arg → todos.                           |
| `sgg doctor`                             | Health HTTP + disco + `pgbackrest info`.                 |
| `sgg backup-now`                         | Backup **incremental** manual (rápido).                  |
| `sgg backup-full`                        | Backup **full** manual (el cron ya lo hace semanal).     |
| `sgg restore-pitr "YYYY-MM-DD HH:MM:SS"` | Restaura a punto-en-el-tiempo. **Destructivo**.          |
| `sgg status`                             | `docker compose ps`.                                     |
| `sgg version`                            | Versión pinneada en `.env`.                              |

## Actualizar a una versión nueva

```bash
sudo sed -i 's/^SGG_VERSION=.*/SGG_VERSION="0.1.2"/' /opt/sgg/.env
sudo sgg update
```

O reinstalar apuntando a la versión: `SGG_VERSION=0.1.2 sudo bash -c "$(curl ...)"`
(no borra `.env`, sólo actualiza compose + CLI + tag).

## Restaurar a un punto anterior

```bash
sudo sgg restore-pitr "2026-07-25 14:30:00"
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
