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
- Tema claro y oscuro.

## Instalar

1. Descarga `RevixPC-x.y.z.zip` desde [Releases](https://github.com/Marco11Mz/RevixPC/releases/latest).
2. Descomprímelo, clic derecho en `RevixPC.ps1` > **Ejecutar con PowerShell** y acepta el aviso de administrador.
3. Lee y acepta la bienvenida. Revix PC se instala sola en *Archivos de programa* con accesos directos.

Para desinstalar: **Configuración > Aplicaciones > Revix PC** (o Ajustes > Avanzado dentro de la app).

> Windows puede mostrar un aviso porque el script no está firmado. Descarga Revix PC solo desde esta página.

## Preguntas frecuentes

**Windows dice "Windows protegió su PC" o que el script no es seguro.**
Pasa con los programas nuevos que no tienen firma digital (cuesta dinero). Si lo descargaste de esta página, pulsa *Más información > Ejecutar de todas formas*. Si lo descargaste de otro sitio, no lo abras.

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

## Licencia

[MIT](LICENSE) © 2026 Marco11
