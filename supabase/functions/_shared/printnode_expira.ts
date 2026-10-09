// [1039] Expiración de printjobs en PrintNode — un ticket viejo no se imprime.
//
// Problema: un día sin luz las impresoras están apagadas; PrintNode deja los jobs en cola y los retiene
// hasta 14 días (default, 1.209.600 s). Al prender la impresora salía TODO lo acumulado (miles de tickets).
// Regla del dueño: un ticket vive como MÁXIMO 1 HORA y nunca pasa del fin del día (America/Lima). Si se va
// la luz al mediodía y se venden 500 tickets, al volver no salen los 500. Para reimprimir está el botón de
// MOS (crea un job nuevo).
//
// Campo de la API (docs PrintNode, POST /printjobs, raíz del JSON): `expireAfter` (entero, segundos)
// "The maximum number of seconds PrintNode should retain this print job in the event that the print job
// cannot be printed immediately." La doc no declara mínimo ni máximo; acotamos nosotros.
//
// Lima es UTC-5 fijo (Perú no tiene horario de verano) → no hace falta base de datos de zonas horarias.

const LIMA_OFFSET_MS = -5 * 3600 * 1000;      // UTC-5 fijo
export const EXPIRA_MIN_S = 120;              // margen mínimo: un ticket emitido a las 23:59 igual tiene 2 min
export const EXPIRA_TICKET_S = 3600;          // vida máxima por defecto de un ticket: 1 hora
export const EXPIRA_MAX_S = 86400;            // tope del valor explícito (igual se acota a fin de día)

// Segundos crudos (sin piso) desde `ahora` hasta las 23:59:59 de HOY en Lima.
function _crudoHastaFinDiaLima(ahora: Date): number {
  // "Hora de pared" de Lima expresada como si fuera UTC → su medianoche se saca con aritmética simple.
  const limaMs = ahora.getTime() + LIMA_OFFSET_MS;
  const inicioDiaLima = Math.floor(limaMs / 86400000) * 86400000;
  const finDiaLima = inicioDiaLima + 86399000;             // 23:59:59.000 de hoy (hora Lima)
  return Math.floor((finDiaLima - limaMs) / 1000);
}

/** Segundos desde `ahora` hasta las 23:59:59 de HOY en Lima, con piso EXPIRA_MIN_S. */
export function segundosHastaFinDiaLima(ahora: Date = new Date()): number {
  return Math.max(EXPIRA_MIN_S, _crudoHastaFinDiaLima(ahora));
}

/** Vida de un job: min(tope, hasta fin del día Lima), con piso EXPIRA_MIN_S. Default tope = 1 hora. */
export function expiraTicketSegundos(ahora: Date = new Date(), tope: number = EXPIRA_TICKET_S): number {
  return Math.max(EXPIRA_MIN_S, Math.min(tope, _crudoHastaFinDiaLima(ahora)));
}

export type ExpiraResuelto = { ok: true; expireAfter: number | null } | { ok: false; error: string };

/**
 * Resuelve la política pedida por el llamador (campo opcional `expira` del body):
 *   • ausente / null / '' / 'fin_dia' → min(1 hora, fin del día Lima) (DEFAULT). 'fin_dia' se mantiene
 *     como alias del default por compatibilidad; ya NO significa "hasta las 23:59:59".
 *   • 'nunca'                          → expireAfter=null → NO se manda el campo (retención default de PrintNode).
 *   • entero de segundos (número o string numérico) en [EXPIRA_MIN_S, EXPIRA_MAX_S], acotado a fin de día.
 * Cualquier otra cosa → { ok:false } (el llamador responde 400; no se imprime con una política adivinada).
 */
export function resolverExpira(expira: unknown, ahora: Date = new Date()): ExpiraResuelto {
  if (expira === undefined || expira === null || expira === '' || expira === 'fin_dia') {
    return { ok: true, expireAfter: expiraTicketSegundos(ahora) };
  }
  if (expira === 'nunca') return { ok: true, expireAfter: null };
  const txt = typeof expira === 'number' ? String(expira) : (typeof expira === 'string' ? expira.trim() : '');
  if (/^\d+$/.test(txt)) {
    const n = Number(txt);
    if (Number.isSafeInteger(n) && n >= EXPIRA_MIN_S && n <= EXPIRA_MAX_S) {
      return { ok: true, expireAfter: expiraTicketSegundos(ahora, n) };
    }
  }
  return { ok: false, error: `expira inválido (fin_dia | nunca | segundos ${EXPIRA_MIN_S}-${EXPIRA_MAX_S})` };
}

/** Fragmento para mezclar en el JSON del printjob: `{ expireAfter }` o `{}` si la política es 'nunca'. */
export function campoExpira(r: { expireAfter: number | null }): { expireAfter?: number } {
  return r.expireAfter == null ? {} : { expireAfter: r.expireAfter };
}
