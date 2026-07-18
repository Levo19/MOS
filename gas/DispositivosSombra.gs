/**
 * DispositivosSombra.gs — [CUTOVER CERO-GAS] Lectura de dispositivos 100% Supabase.
 *
 * Fuente de verdad = mos.dispositivos. Estos helpers reemplazan a `getSheet('DISPOSITIVOS')` /
 * `_sheetToObjects(getSheet('DISPOSITIVOS'))` en TODOS los lectores GAS. Devuelven filas con el MISMO
 * shape que daba la hoja (llaves PascalCase de columna: ID_Dispositivo, Estado, Ultima_Conexion, …), para
 * que cada lector sea un swap mecánico de 1 línea sin tocar su lógica.
 *
 * Reusa el mapa columna↔snake (_DISP_MAP_F4) y el escritor (_dualWriteDispositivo) que hoy viven en
 * Fase4Dispositivos.gs; al matar el sync (fase final) esos helpers se consolidan acá y Fase4 se borra.
 *
 * Conversión de valor (snake sombra → valor-hoja), coherente con cómo GAS leía la hoja:
 *   ts   → string ISO con Z (full precision; el front/crons ya parsean ISO). '' si vacío.
 *   bool → '1' | '' (idéntico a _f4ToBool / como se guardaba en la hoja).
 *   json → string JSON.
 *   text → string.
 */

/** Convierte un valor de la SOMBRA (snake) al valor que la HOJA entregaba para esa columna. */
function _dispHojaVal(tipo, v) {
  if (v == null || v === '') return '';
  if (tipo === 'ts') {
    var d = new Date(v);
    return isNaN(d.getTime()) ? String(v) : d.toISOString();
  }
  if (tipo === 'bool') return _f4ToBool(v) ? '1' : '';
  if (tipo === 'json') return (typeof v === 'object') ? JSON.stringify(v) : String(v);
  return String(v);
}

/** Inverso del mapa columna-hoja→snake: { snake: [colHoja, tipo] }. Se calcula 1 vez (memo). */
var _DISP_INV_MAP = null;
function _dispInvMap() {
  if (_DISP_INV_MAP) return _DISP_INV_MAP;
  var inv = {};
  for (var colHoja in _DISP_MAP_F4) {
    if (!Object.prototype.hasOwnProperty.call(_DISP_MAP_F4, colHoja)) continue;
    inv[_DISP_MAP_F4[colHoja][0]] = [colHoja, _DISP_MAP_F4[colHoja][1]];
  }
  _DISP_INV_MAP = inv;
  return inv;
}

/**
 * _dispositivosDesdeSombra(opts) — lee mos.dispositivos y devuelve un array de objetos con llaves de
 * COLUMNA DE HOJA (shape de _sheetToObjects). Reemplazo directo de _sheetToObjects(getSheet('DISPOSITIVOS')).
 *   opts.filters = { estado:'eq.ACTIVO', app:'eq.MOS', ... }  (sintaxis PostgREST, columnas snake)
 *   opts.order   = 'ultima_conexion.desc'
 *   opts.limit   = 5000 (default)
 * Lanza si Supabase falla (fail-closed en el gate; los paneles lo propagan y el usuario reintenta).
 */
function _dispositivosDesdeSombra(opts) {
  opts = opts || {};
  var q = { select: opts.select || '*', limit: (opts.limit != null ? opts.limit : 5000) };
  if (opts.filters) q.filters = opts.filters;
  if (opts.order)   q.order   = opts.order;
  var sel = _sbSelect('mos.dispositivos', q);
  if (!sel.ok) throw new Error('lectura sombra dispositivos falló: HTTP ' + sel.code + ' ' + (sel.error || ''));
  var rows = sel.data || [];
  var inv = _dispInvMap();
  return rows.map(function (sr) {
    var o = {};
    for (var snake in inv) {
      if (!Object.prototype.hasOwnProperty.call(inv, snake)) continue;
      o[inv[snake][0]] = _dispHojaVal(inv[snake][1], sr[snake]);
    }
    return o;
  });
}

/** _dispositivoDesdeSombra(id) — un solo dispositivo por ID (shape de hoja) o null si no existe. */
function _dispositivoDesdeSombra(id) {
  var id2 = String(id || '').trim();
  if (!id2) return null;
  var arr = _dispositivosDesdeSombra({ filters: { id_dispositivo: 'eq.' + id2 }, limit: 1 });
  return arr.length ? arr[0] : null;
}
