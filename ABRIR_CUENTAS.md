# Llamadas con IA — las cuentas que tiene que abrir Daniel

Mañana Claude te guía **un paso a la vez**. Esta hoja sirve para tener todo a mano.

**Reglas:**
- Las llaves (API keys) **nunca** se pegan en el chat. Solo en las páginas que dice aquí.
- Claude no paga nada: las tarjetas las pones tú.

**Cuánto cuesta, más o menos:** unos $11 al mes fijos (el número y el servidor), más unos 3 a 4 centavos por minuto de llamada.

---

## 1. Fly.io: el servidor que contesta (unos $5 a $10 al mes)
1. Entra a fly.io y toca **Sign up**. Usa **"Sign up with GitHub"** con tu cuenta de GitHub (la de la app).
2. Pon tu tarjeta en **Billing**. Fly la pide para prender servidores.
3. Entra a **Tokens** (en el menú de tu cuenta o de la organización) → **Create token** → tipo **Organization**, nombre `github-voz` → copia el token.
4. Ese token se pega en GitHub (paso 6) con el nombre `FLY_API_TOKEN`.

## 2. Telnyx: el número de teléfono (unos $1 al mes por número, más los minutos)
1. Entra a telnyx.com → **Sign up**. Verifica tu correo y tu teléfono.
2. Pon saldo (Telnyx es de prepago): **Billing → Add funds**, la recarga mínima que te pida.
3. **API Keys** → **Create API Key** → cópiala. Va en GitHub como `TELNYX_API_KEY` y en Supabase con el mismo nombre (pasos 6 y 7).
4. **Keys & Credentials → Public Key** → cópiala. Va en GitHub como `TELNYX_PUBLIC_KEY`.
5. El número y la "TeXML Application" los hace Claude contigo después del paso 8, porque necesitan que el servidor ya esté prendido.

## 3. Deepgram: la que escucha (paga por minuto)
1. Entra a deepgram.com → **Sign up**.
2. **API Keys → Create a New API Key** → cópiala. Va en GitHub como `DEEPGRAM_API_KEY`.

## 4. ElevenLabs: la voz
1. Entra a elevenlabs.io → **Sign up**. Para usarla en un negocio hace falta un plan pagado (el más barato sirve para empezar).
2. Tu foto → **API Keys** → **Create** → cópiala. Va en GitHub como `ELEVENLABS_API_KEY`.
3. **Voices / Voice Library**: escoge una voz en español que te guste → **ID** (Voice ID) → cópialo. Va en GitHub como `ELEVENLABS_VOICE_ID`.

## 5. Dos claves que inventas tú
Escribe dos claves largas, de **30 letras y números al azar** cada una. No uses palabras ni fechas. Por ejemplo, saca una de un generador de contraseñas.
- `TELEFONO_SECRETO`: va en GitHub **y** en Supabase. Tiene que ser la misma en los dos.
- `VOZ_URL_CLAVE`: va en GitHub. Claude te dice dónde ponerla en Telnyx.

## 6. GitHub: guardar las llaves (solo aquí y en Supabase)
github.com → el repositorio **dani-negocios** → **Settings → Secrets and variables → Actions → New repository secret**.
Se crea uno por cada nombre:
`FLY_API_TOKEN`, `TELNYX_API_KEY`, `TELNYX_PUBLIC_KEY`, `DEEPGRAM_API_KEY`, `ELEVENLABS_API_KEY`, `ELEVENLABS_VOICE_ID`, `TELEFONO_SECRETO`, `VOZ_URL_CLAVE`.

## 7. Supabase: las llaves del cerebro
Supabase → **Edge Functions → Secrets** → **Add new secret**:
- `TELEFONO_SECRETO` (la misma del paso 5)
- `TELNYX_API_KEY`
- `TELNYX_TEXML_APP_ID`: este lo pone Claude contigo en el paso 8.

## 8. Lo que hace Claude cuando esté todo
1. En GitHub → **Actions → "Servidor de voz (Fly.io)" → Run workflow**. Sube el servidor a Miami y revisa que conteste.
2. Contigo en Telnyx:
   - crear la **TeXML Application** con la dirección `https://voz-danipro.fly.dev/voz?k=` + tu `VOZ_URL_CLAVE` (POST);
   - copiar su ID para el paso 7.
3. Compra el número de Tampa (813) solo, con la función `numero`, y lo pone en tu negocio.
4. Tú pones el desvío en el teléfono del negocio: "cuando no contesto / ocupado", hacia el número nuevo.
5. **Primera llamada de prueba desde tu celular.**
