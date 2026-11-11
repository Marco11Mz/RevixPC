# Revix PC

[![Última versión](https://img.shields.io/github/v/release/Marco11Mz/RevixPC?label=versi%C3%B3n)](https://github.com/Marco11Mz/RevixPC/releases/latest) [![Licencia MIT](https://img.shields.io/badge/licencia-MIT-blue)](LICENSE) ![Windows 10 | 11](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D6)

Revisa y actualiza tu PC con Windows 10 y 11 desde un solo lugar: programas, Windows Update, drivers, salud del equipo y limpieza.

*Free, open-source Windows 10/11 maintenance app (Spanish UI; English coming in 4.3.0).*

## Qué hace

- **Programas**: muestra los que tienen versión nueva y los actualiza con winget. Puedes saltar una versión, ignorar programas, marcar algunos como automáticos y volver a la versión anterior.
- **Windows Update**: busca e instala actualizaciones de Windows y drivers, una por una.
- **Dispositivos**: revisa tus drivers y te lleva a la página oficial de cada marca cuando conviene revisarlos ahí.
- **Salud**: antivirus, firewall, discos, espacio libre, apagados inesperados y pantallazos azules de los últimos 30 días.
- **Limpieza**, **Inicio de Windows**, **Desinstalar** y **Mi PC** (ficha del equipo y temperaturas).
- **Modo juego**: mientras juegas no avisa, no revisa y no instala nada.
- Avisa cuando Windows tiene un **reinicio pendiente** para terminar actualizaciones.
- Tema claro y oscuro.

## Instalar

1. Descarga **`RevixPC-Setup-x.y.z.exe`** desde [Releases](https://github.com/Marco11Mz/RevixPC/releases/latest).
2. Ábrelo, acepta el aviso de administrador y sigue los pasos.
3. Abre Revix PC desde el Escritorio o el menú Inicio.

Las versiones nuevas se instalan desde la misma app (Ajustes > Buscar nueva versión ahora). Antes de instalar, Revix PC comprueba que el archivo venga de esta página y que su huella SHA-256 sea la publicada.

**Versión portátil** (sin instalar): descarga `RevixPC-Portable-x.y.z.zip`, descomprímelo y abre `RevixPC.exe`. No inicia con Windows ni se actualiza sola.

Para desinstalar: **Configuración > Aplicaciones > Revix PC** (o Ajustes > Avanzado dentro de la app).

> El instalador todavía no tiene firma digital, así que Windows puede mostrar un aviso. Descarga Revix PC solo desde esta página.

**Comprobar la descarga (opcional):** en PowerShell, `Get-FileHash .\RevixPC-Setup-x.y.z.exe` debe dar la misma huella SHA-256 que aparece en las notas de la versión.

## Preguntas frecuentes

**Windows dice "Windows protegió su PC" o que el script no es seguro.**
Pasa con los programas nuevos que no tienen firma digital. Si lo descargaste de esta página, pulsa *Más información > Ejecutar de todas formas*. Si lo descargaste de otro sitio, no lo abras.

**Mi antivirus marca Revix PC.**
Puede ser un falso positivo (pasa con programas nuevos sin firma). Revisa que lo descargaste de esta página y que la huella SHA-256 coincida. Si quieres, avísanos en [Issues](https://github.com/Marco11Mz/RevixPC/issues) indicando qué antivirus fue.

**Vengo de ActualizaPC o de la 4.2.0.**
Instala con `RevixPC-Setup`. El instalador quita lo viejo y Revix PC trae tus ajustes e historial.

**¿Necesita permisos de administrador?**
Sí, para instalar actualizaciones de Windows, crear puntos de restauración y respaldar drivers.

**¿Me va a desinstalar o cambiar algo sin preguntar?**
No. Siempre te muestra la lista y pide confirmación. Solo los programas que tú marques como "Automático" se actualizan solos.

**¿Cómo la quito?**
Configuración > Aplicaciones > Revix PC > Desinstalar. Te pregunta si quieres borrar también tus ajustes.

## Privacidad

Revix PC **no envía tus datos a nadie**. Todo se revisa en tu PC. Solo se conecta a Microsoft (winget, Windows Update, Defender), a NVIDIA (si tienes tarjeta NVIDIA, para ver el último driver) y a GitHub (para buscar versiones nuevas).

## Aviso

- Al actualizar programas, winget acepta en tu nombre los acuerdos de licencia de esos programas.
- Se ofrece **tal cual, sin garantía** (licencia MIT). Úsala bajo tu responsabilidad y ten copia de tus archivos.
- Revix PC no está afiliado ni respaldado por Microsoft, NVIDIA, AMD, Intel, Logitech, Razer, HyperX ni otras marcas mencionadas. Sus nombres pertenecen a sus dueños.

## Requisitos

Windows 10 u 11 con Windows PowerShell 5.1 (viene con Windows) y el "Instalador de aplicación" (winget) de Microsoft Store.

## Cómo se arma (para quien quiera revisar el código)

- `RevixPC.ps1`: la app (PowerShell 5.1 + WPF).
- `launcher/Launcher.cs`: `RevixPC.exe`, abre `RevixPC.ps1` dentro del mismo proceso.
- `installer/RevixPC.iss`: instalador con [Inno Setup](https://jrsoftware.org/isinfo.php).
- `.github/workflows/release.yml`: GitHub Actions arma el instalador y el .zip al publicar una versión y agrega las huellas SHA-256.

## Licencia

[MIT](LICENSE) © 2026 Marco11
