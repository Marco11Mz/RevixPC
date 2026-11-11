# Cambios

Formato: Nuevo / Mejorado / Corregido. Versiones con [versionado semántico](https://semver.org/lang/es/).

## [4.2.1] - 2026-11

### Nuevo
- **Instalador** `RevixPC-Setup-4.2.1.exe`: instala en *Archivos de programa*, crea accesos directos y se desinstala desde **Aplicaciones** de Windows. Al desinstalar pregunta si borrar tus ajustes.
- **Versión portátil** `RevixPC-Portable-4.2.1.zip` (abrir `RevixPC.exe`, sin instalar).
- Windows Update: las actualizaciones que ya se instalaron y solo esperan reiniciar se muestran como **"Instalada · falta reiniciar"** y ya no cuentan como pendientes.
- Aviso **"Reinicio pendiente"** en Resumen, con botón para reiniciar (pregunta antes).
- Windows Update: si una actualización falló antes, se muestra junto a ella con la fecha y el código del error.

### Mejorado
- Cuando hay una versión nueva, Revix PC muestra las novedades y abre la página oficial para descargar el instalador (ya no descarga ni ejecuta archivos por su cuenta).
- La limpieza de "Descargas de Windows Update" ya no detiene servicios de Windows; lo que esté en uso se salta.
- "Reiniciar" usa el reinicio normal de Windows (los programas abiertos pueden pedirte guardar).
- `RevixPC.exe` abre la app dentro del mismo proceso, sin ventanas ocultas de PowerShell ni `-ExecutionPolicy Bypass`. Menos motivos para que un antivirus la confunda.
- La app ya no compila nada en tu PC ni usa comandos de consola para desinstalarse (ahora lo hace el instalador).
- Las notas de cada versión incluyen las huellas SHA-256 de los archivos.

### Corregido
- Estados de colores en las tablas (pastillas) que en algunos equipos salían sin color.

### Quitado
- "Instalar desde un archivo .zip" y "Reparar instalación" (ahora: volver a ejecutar el instalador).

## [4.2.0] - 2026-11

### Nuevo
- Nuevo nombre: **Revix PC** (antes ActualizaPC). Tus ajustes e historial se traen solos.
- Tema claro y oscuro (botón en la barra de la ventana y en Ajustes > Apariencia; también "Igual que Windows").
- Bienvenida con aviso de licencias, responsabilidad y privacidad.
- Instalación automática en *Archivos de programa*, con entrada en **Aplicaciones** de Windows para desinstalar.
- Sección **Acerca de** (autor, licencia MIT, privacidad y marcas).
- Busca versiones nuevas en las releases de GitHub y muestra las **Novedades**. Comprueba la huella SHA-256 del archivo antes de instalarlo.

### Mejorado
- Estados más legibles en las tablas: texto blanco sobre color sólido.
- Antes de encender la protección del sistema para crear un punto de restauración, ahora pregunta. Además deja el ajuste de Windows como estaba.
- Opciones técnicas (instalar desde .zip, carpeta de datos) movidas a Ajustes > Avanzado.
- Los enlaces de las tablas solo abren direcciones https.

### Corregido
- Al maximizar, la ventana ya no tapa la barra de tareas.

### Quitado
- Campo de dirección de version.json (ya no hace falta).
