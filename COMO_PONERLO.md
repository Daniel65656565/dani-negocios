# Llamadas con IA — cómo se pone a funcionar

## Cómo funciona

Alguien llama al número de siempre del negocio → si nadie contesta, se desvía al número de **Telnyx** → nuestro **servidor de voz** →
- **Deepgram** escucha y pasa la voz a texto (español e inglés mezclados)
- el **cerebro** (`funciones/telefono` en Supabase) busca en las fichas y le pregunta al motor (Groq)
- **ElevenLabs** convierte la respuesta en voz → Telnyx → la persona la oye

Decidido el 30 oct 2026, después de investigar: **Telnyx** en vez de Twilio, porque es más barato. El programa también funciona con Twilio (`PROVEEDOR=twilio`). El negocio **no cambia su número**: activa el desvío "cuando no contesto u ocupado" hacia el número de Telnyx.

Además:
- Si la persona habla mientras la IA habla, la IA se calla.
- Si se queda callada 15 segundos, la IA pregunta "¿Sigue ahí?". Si sigue callada, se despide.
- Si pide una persona, la IA le pasa la llamada al celular del dueño.
- La IA **no aparta citas**: deja un "pedido de cita" y el dueño lo confirma en la app (pestaña **Llamadas**).
- Al principio avisa que la llamada se graba y se transcribe, como pide la ley de la Florida.

## Lo que ya está hecho (30 oct 2026)

| Pieza | Archivo | Estado |
|---|---|---|
| Tablas (llamadas, pedidos de cita, recados, números) | `sql/30_llamadas.sql` | **en Supabase** |
| Cerebro del teléfono | `funciones/telefono/index.ts` | **en Supabase** (v3), probado por texto: funciona |
| Servidor de voz (Telnyx y Twilio) | `llamadas/servidor.js` | escrito y probado con piezas de mentira (`node prueba_servidor.js telnyx` y `twilio`): llamada completa, interrupción y pasar a persona |
| Panel del dueño + llamada de prueba por texto | `app/src/vistas20.js` | **publicado** en la app |

## Lo que tiene que hacer Daniel (con la computadora)

1. **Telnyx** (telnyx.com): abrir la cuenta, comprar un número de Tampa ($1 al mes), sacar la llave de la API y copiar la llave pública.
2. **Deepgram** (deepgram.com): abrir la cuenta y sacar una llave (API key).
3. **ElevenLabs** (elevenlabs.io): abrir la cuenta, escoger una voz en español y sacar una llave.
4. **Fly.io** (fly.io): abrir la cuenta. El servidor queda prendido siempre, por unos $5 a $10 al mes.
5. Las llaves las pega Daniel en los "secrets". Claude nunca las ve.

## Después Claude hace

1. `fly launch` / `fly deploy` desde esta carpeta. Las llaves se ponen con `fly secrets set ...`, y las pega Daniel.
2. En Telnyx: crear una "TeXML Application" con la dirección `https://<servidor>/voz?k=<VOZ_URL_CLAVE>` (POST) y ponerle el número.
3. En el teléfono del negocio: desvío "cuando no contesto / ocupado" hacia el número de Telnyx.
4. En Supabase, la tabla `telefonos_negocio` recibe una fila con el número, el negocio y el celular para pasar llamadas.
5. Primera llamada de prueba desde el celular de Daniel.

## Costos esperados

Unos **$0.035 a $0.04 por minuto** con Telnyx, más unos **$11 al mes** (el número y el servidor). Pasar una llamada a una persona cuesta $0.10 más los minutos de las dos líneas: usarlo poco.

Cada número tiene un **tope de minutos al mes** (de fábrica 600). Al llegar al tope, la llamada se pasa directo al dueño.
