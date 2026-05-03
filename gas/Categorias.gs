// ============================================================
// ProyectoMOS — Categorias.gs
// Política de precios por categoría + CRUD.
// Migración idempotente: si la hoja CATEGORIAS no existe, la crea
// y la pre-puebla con las categorías que ya están usadas en
// PRODUCTOS_MASTER. Default: MARGEN 25%.
// ============================================================

var _DEFAULT_MARGEN_PCT = 25;
var _DEFAULT_MODO_VENTA = 'MARGEN';
var _MODOS_VALIDOS = ['MARGEN', 'FIJO', 'COMPETITIVO', 'LIBRE'];

// ── Helpers ─────────────────────────────────────────────────

function _normalizarIdCategoria(s) {
  // Slug consistente: MAYÚSCULAS, sin espacios extras (es como están en PRODUCTOS_MASTER hoy)
  return String(s || '').trim().toUpperCase();
}

function _garantizarHojaCategorias() {
  var ss = getSpreadsheet();
  var sheet = ss.getSheetByName('CATEGORIAS');
  if (sheet) return sheet;
  sheet = ss.insertSheet('CATEGORIAS');
  sheet.getRange(1, 1, 1, MOS_HEADERS.CATEGORIAS.length).setValues([MOS_HEADERS.CATEGORIAS]);
  sheet.getRange(1, 1, 1, MOS_HEADERS.CATEGORIAS.length)
       .setBackground('#0f3460').setFontColor('#e2e8f0').setFontWeight('bold').setFontSize(10);
  sheet.setFrozenRows(1);
  sheet.setColumnWidths(1, MOS_HEADERS.CATEGORIAS.length, 150);
  return sheet;
}

// Garantiza que PRODUCTOS_MASTER tenga las columnas modoVenta, margenPct, precioTope.
// Si faltan, las agrega al final (no rompe data existente).
function _garantizarColumnasPoliticaProductos() {
  var sheet = getSheet('PRODUCTOS_MASTER');
  if (!sheet) return;
  var headers = sheet.getRange(1, 1, 1, sheet.getLastColumn()).getValues()[0];
  var faltantes = [];
  ['modoVenta', 'margenPct', 'precioTope'].forEach(function(col) {
    if (headers.indexOf(col) === -1) faltantes.push(col);
  });
  if (!faltantes.length) return;
  var startCol = sheet.getLastColumn() + 1;
  sheet.getRange(1, startCol, 1, faltantes.length).setValues([faltantes])
       .setBackground('#0f3460').setFontColor('#e2e8f0').setFontWeight('bold').setFontSize(10);
}

// Migración: poblar CATEGORIAS con las categorías que ya están en PRODUCTOS_MASTER.
// Idempotente: solo agrega las que no existan.
function _seedCategoriasDesdeProductos() {
  var shCat = _garantizarHojaCategorias();
  var existentes = _sheetToObjects(shCat);
  var idsExistentes = {};
  existentes.forEach(function(c){ idsExistentes[_normalizarIdCategoria(c.idCategoria)] = true; });

  var productos = _sheetToObjects(getSheet('PRODUCTOS_MASTER'));
  var nuevas = {};
  productos.forEach(function(p){
    var id = _normalizarIdCategoria(p.idCategoria);
    if (!id) return;
    if (idsExistentes[id]) return;
    nuevas[id] = true;
  });

  var rows = Object.keys(nuevas).map(function(id){
    return [
      id,                          // idCategoria
      id,                          // nombre (mismo string al inicio, editable después)
      _DEFAULT_MODO_VENTA,         // modoVenta
      _DEFAULT_MARGEN_PCT,         // margenPct
      '',                          // precioTope
      '',                          // descripcion
      1,                           // estado activo
      new Date()                   // fechaCreacion
    ];
  });
  if (rows.length) {
    shCat.getRange(shCat.getLastRow() + 1, 1, rows.length, MOS_HEADERS.CATEGORIAS.length).setValues(rows);
  }
  return rows.length;
}

// Endpoint: ejecutar una sola vez para preparar el sistema.
// Idempotente — se puede correr varias veces sin daño.
function migrarPoliticaPrecios() {
  _garantizarHojaCategorias();
  _garantizarColumnasPoliticaProductos();
  var nuevas = _seedCategoriasDesdeProductos();
  return { ok: true, data: { categoriasNuevas: nuevas } };
}

// ── CRUD ────────────────────────────────────────────────────

function getCategorias(params) {
  _garantizarHojaCategorias();
  var rows = _sheetToObjects(getSheet('CATEGORIAS'));
  // Ordenar por nombre, activos primero
  rows.sort(function(a, b){
    var ea = String(a.estado) === '1' ? 0 : 1;
    var eb = String(b.estado) === '1' ? 0 : 1;
    if (ea !== eb) return ea - eb;
    return String(a.nombre || '').localeCompare(String(b.nombre || ''));
  });
  return { ok: true, data: rows };
}

function _validarParamsCategoria(params) {
  var modo = String(params.modoVenta || _DEFAULT_MODO_VENTA).toUpperCase();
  if (_MODOS_VALIDOS.indexOf(modo) === -1) {
    return { ok: false, error: 'modoVenta inválido. Debe ser uno de: ' + _MODOS_VALIDOS.join(', ') };
  }
  var margen = parseFloat(params.margenPct);
  if (modo === 'MARGEN' || modo === 'COMPETITIVO') {
    if (isNaN(margen) || margen < 0 || margen >= 100) {
      return { ok: false, error: 'margenPct inválido (0-99)' };
    }
  }
  var tope = parseFloat(params.precioTope);
  if (modo === 'COMPETITIVO' && (isNaN(tope) || tope <= 0)) {
    return { ok: false, error: 'precioTope requerido para modo COMPETITIVO' };
  }
  return { ok: true, data: { modo: modo, margen: isNaN(margen) ? '' : margen, tope: isNaN(tope) ? '' : tope } };
}

function crearCategoria(params) {
  if (!params.nombre || !String(params.nombre).trim()) {
    return { ok: false, error: 'nombre requerido' };
  }
  var v = _validarParamsCategoria(params);
  if (!v.ok) return v;

  var sheet = _garantizarHojaCategorias();
  var rows = _sheetToObjects(sheet);
  var id = _normalizarIdCategoria(params.idCategoria || params.nombre);
  if (rows.some(function(r){ return _normalizarIdCategoria(r.idCategoria) === id; })) {
    return { ok: false, error: 'Ya existe una categoría con ese ID: ' + id };
  }
  sheet.appendRow([
    id,
    String(params.nombre).trim(),
    v.data.modo,
    v.data.margen,
    v.data.tope,
    String(params.descripcion || '').trim(),
    1,
    new Date()
  ]);
  return { ok: true, data: { idCategoria: id } };
}

function actualizarCategoria(params) {
  if (!params.idCategoria) return { ok: false, error: 'idCategoria requerido' };
  var v = _validarParamsCategoria(params);
  if (!v.ok) return v;
  var sheet = _garantizarHojaCategorias();
  var data = sheet.getDataRange().getValues();
  var hdrs = data[0];
  var idxId  = hdrs.indexOf('idCategoria');
  if (idxId < 0) return { ok: false, error: 'Schema inválido en CATEGORIAS' };
  var idBuscado = _normalizarIdCategoria(params.idCategoria);
  for (var i = 1; i < data.length; i++) {
    if (_normalizarIdCategoria(data[i][idxId]) !== idBuscado) continue;
    var actualizar = {
      nombre:      params.nombre,
      modoVenta:   v.data.modo,
      margenPct:   v.data.margen,
      precioTope:  v.data.tope,
      descripcion: params.descripcion,
      estado:      params.estado !== undefined ? params.estado : data[i][hdrs.indexOf('estado')]
    };
    Object.keys(actualizar).forEach(function(campo) {
      var col = hdrs.indexOf(campo);
      if (col < 0) return;
      var nuevoValor = actualizar[campo];
      if (nuevoValor === undefined) return;
      sheet.getRange(i + 1, col + 1).setValue(nuevoValor);
    });
    return { ok: true };
  }
  return { ok: false, error: 'Categoría no encontrada: ' + idBuscado };
}

// ── Política efectiva (override producto > categoría > default) ──

// Construye un mapa idCategoria → política, listo para resolver rápido.
function _cargarMapaPoliticaCategorias() {
  _garantizarHojaCategorias();
  var rows = _sheetToObjects(getSheet('CATEGORIAS'));
  var map = {};
  rows.forEach(function(c){
    var id = _normalizarIdCategoria(c.idCategoria);
    if (!id) return;
    map[id] = {
      modoVenta:  String(c.modoVenta  || _DEFAULT_MODO_VENTA).toUpperCase(),
      margenPct:  parseFloat(c.margenPct)  || _DEFAULT_MARGEN_PCT,
      precioTope: parseFloat(c.precioTope) || 0,
      activo:     String(c.estado) === '1'
    };
  });
  return map;
}

// Resuelve la política efectiva para un producto: override producto > categoría (con
// herencia desde canónico si la presentación/derivado no la tiene) > default global.
// mapaCanonicos opcional: { byIdProducto, bySkuBase } — si se pasa, presentaciones
// y derivados sin idCategoria heredan la categoría de su canónico.
function _resolverPoliticaProducto(producto, mapaCategorias, mapaCanonicos) {
  // Resolver idCategoria efectiva (con herencia si aplica)
  var idCat = _normalizarIdCategoria(producto.idCategoria);
  var origenCat = idCat ? 'PROPIO' : '';
  if (!idCat && mapaCanonicos) {
    var canonico = _buscarCanonicoDe(producto, mapaCanonicos);
    if (canonico && canonico.idCategoria) {
      idCat = _normalizarIdCategoria(canonico.idCategoria);
      origenCat = 'HEREDADA';
    }
  }
  var cat = idCat ? mapaCategorias[idCat] : null;

  // Override del producto (si tiene)
  var oModo  = String(producto.modoVenta || '').toUpperCase();
  var oMarg  = producto.margenPct  !== '' && producto.margenPct  !== undefined && producto.margenPct  !== null ? parseFloat(producto.margenPct)  : null;
  var oTope  = producto.precioTope !== '' && producto.precioTope !== undefined && producto.precioTope !== null ? parseFloat(producto.precioTope) : null;

  var modoEf  = (_MODOS_VALIDOS.indexOf(oModo) >= 0) ? oModo : (cat ? cat.modoVenta : _DEFAULT_MODO_VENTA);
  var margEf  = (oMarg !== null && !isNaN(oMarg)) ? oMarg : (cat ? cat.margenPct : _DEFAULT_MARGEN_PCT);
  var topeEf  = (oTope !== null && !isNaN(oTope) && oTope > 0) ? oTope : (cat ? cat.precioTope : 0);

  var origen = oModo ? 'PRODUCTO' : (cat ? 'CATEGORIA' : 'DEFAULT');

  return {
    modoVenta: modoEf, margenPct: margEf, precioTope: topeEf,
    origen: origen, idCategoria: idCat, origenCategoria: origenCat
  };
}

// Construye mapa de canónicos { byIdProducto, bySkuBase } a partir de PRODUCTOS_MASTER.
function _cargarMapaCanonicos() {
  var productos = _sheetToObjects(getSheet('PRODUCTOS_MASTER'));
  var byId = {}, bySku = {};
  productos.forEach(function(p) {
    if (_esCanonico(p)) {
      if (p.idProducto) byId[String(p.idProducto).toUpperCase()] = p;
      if (p.skuBase)    bySku[String(p.skuBase).toUpperCase()]    = p;
    }
  });
  return { byIdProducto: byId, bySkuBase: bySku };
}

// Determina si un producto es canónico (= base / sin presentación).
function _esCanonico(p) {
  if (p.codigoProductoBase && String(p.codigoProductoBase).trim()) return false;
  var f = p.factorConversion;
  if (f === '' || f === null || f === undefined) return true;
  var fn = parseFloat(f);
  return isNaN(fn) || fn === 1;
}

// Busca el canónico al que pertenece un producto (presentación o derivado).
function _buscarCanonicoDe(producto, mapaCanonicos) {
  // Derivado (envasado de un envasable)
  if (producto.codigoProductoBase && String(producto.codigoProductoBase).trim()) {
    var ref = String(producto.codigoProductoBase).toUpperCase();
    return mapaCanonicos.byIdProducto[ref] || mapaCanonicos.bySkuBase[ref];
  }
  // Presentación (mismo skuBase, factor != 1)
  var f = parseFloat(producto.factorConversion);
  if (!isNaN(f) && f !== 1 && producto.skuBase) {
    return mapaCanonicos.bySkuBase[String(producto.skuBase).toUpperCase()];
  }
  return null;
}

// Calcula el precio venta sugerido según política. Retorna null si no aplica (FIJO/LIBRE).
function _calcularPrecioVentaSugerido(costoConIgv, politica) {
  var costo = parseFloat(costoConIgv) || 0;
  if (costo <= 0) return null;
  if (politica.modoVenta === 'FIJO' || politica.modoVenta === 'LIBRE') return null;
  var margen = parseFloat(politica.margenPct) || 0;
  if (margen >= 100) return null;
  var sugerido = costo / (1 - margen / 100);
  if (politica.modoVenta === 'COMPETITIVO' && politica.precioTope > 0) {
    sugerido = Math.min(sugerido, politica.precioTope);
  }
  return Math.round(sugerido * 100) / 100;
}

// Calcula margen real actual: (venta - costo) / venta * 100. Si venta <= 0, retorna null.
function _calcularMargenReal(precioVenta, precioCosto) {
  var pv = parseFloat(precioVenta) || 0;
  var pc = parseFloat(precioCosto) || 0;
  if (pv <= 0) return null;
  return Math.round(((pv - pc) / pv) * 1000) / 10; // 1 decimal
}

// ============================================================
// MIGRACIÓN MASIVA — Clasificación + limpieza unidades + EXO
// ============================================================
// Catálogo inicial de categorías a crear si no existen.
var _CATEGORIAS_INICIALES = [
  { id: 'ABARROTES', nombre: 'Abarrotes secos', margenPct: 22, descripcion: 'Productos secos de despensa: arroz, fideos, harinas, sal, sazonadores' },
  { id: 'ACEITES', nombre: 'Aceites', margenPct: 18, descripcion: 'Aceites vegetales, oliva, ajonjolí (volumen alto, margen menor)' },
  { id: 'BEBIDAS', nombre: 'Bebidas', margenPct: 18, descripcion: 'Gaseosas, agua, jugos, café' },
  { id: 'CONFITERIA', nombre: 'Confitería', margenPct: 28, descripcion: 'Caramelos, chupetines, gomitas' },
  { id: 'CONSERVAS', nombre: 'Conservas', margenPct: 22, descripcion: 'Atún, duraznos, champiñones en lata' },
  { id: 'DECORATIVOS', nombre: 'Decorativos repostería', margenPct: 40, descripcion: 'Bases tecnopor, mariposas, perlas, topers' },
  { id: 'DESCARTABLES', nombre: 'Descartables y envases', margenPct: 28, descripcion: 'Cajas, bolsas, vasos, platos, cubiertos' },
  { id: 'ENDULZANTES', nombre: 'Endulzantes', margenPct: 20, descripcion: 'Azúcar, panela, miel, chancaca' },
  { id: 'ENERGIZANTES', nombre: 'Energizantes', margenPct: 22, descripcion: 'Sporade, Gatorade, Volt, Powerade' },
  { id: 'ESPECIAS', nombre: 'Especias y condimentos', margenPct: 35, descripcion: 'Pimienta, comino, canela, hierbas' },
  { id: 'GALLETAS_SNACKS', nombre: 'Galletas y snacks', margenPct: 22, descripcion: 'Oreo, Costa, Field, papitas' },
  { id: 'GRANEL', nombre: 'Granel y frutos secos', margenPct: 30, descripcion: 'Productos vendidos al peso, frutos secos' },
  { id: 'INFUSIONES', nombre: 'Infusiones', margenPct: 28, descripcion: 'Filtrantes de té, anís, manzanilla, hierba luisa' },
  { id: 'INSUMOS_REPOSTERIA', nombre: 'Insumos repostería', margenPct: 40, descripcion: 'Moldes, mangas, cortadores, boquillas' },
  { id: 'LACTEOS', nombre: 'Lácteos', margenPct: 18, descripcion: 'Leche, mantequilla, queso, crema' },
  { id: 'LIMPIEZA', nombre: 'Limpieza del hogar', margenPct: 22, descripcion: 'Detergentes, lavavajillas, papel higiénico' },
  { id: 'MENESTRAS', nombre: 'Menestras', margenPct: 22, descripcion: 'Frijol, lenteja, garbanzo, pallar, maíz' },
  { id: 'OTROS', nombre: 'Otros', margenPct: 25, descripcion: 'Productos sin categoría específica' },
  { id: 'PRODUCTOS_CHINOS', nombre: 'Productos chinos', margenPct: 28, descripcion: 'Salsa de soya, panko, fideo de arroz, dashi' },
  { id: 'REPOSTERIA', nombre: 'Repostería', margenPct: 32, descripcion: 'Coberturas, fondant, colorantes, esencias' },
  { id: 'SALSAS', nombre: 'Salsas y aderezos', margenPct: 25, descripcion: 'Mayonesa, ketchup, mostaza, sillao' },
  { id: 'VINAGRES', nombre: 'Vinagres', margenPct: 25, descripcion: 'Vinagre blanco, tinto, manzana, balsámico' },
  { id: 'VINOS_LICORES', nombre: 'Vinos y licores', margenPct: 30, descripcion: 'Pisco, vino, mistela' }
];

// Reglas de clasificación. ORDEN IMPORTA — la primera regla que matchea gana.
// De lo más específico a lo más genérico.
var _CLASIFICADOR_REGLAS = [
  { cat: 'INFUSIONES', kw: ['FILTRANTE','INKA MUÑA','TE NEGRO 100','TE NEGRO 250','TE NEGRO 500','HIERBA LUISA','MANZANILLA 25','BOLDO 25','ASMACHILCA','MATE DE COCA','UÑA DE GATO','VALERIANA','TE DE DURAZNO','MUÑA 25','DEL VALLE FILTRANTE','TE HUYRO'] },
  { cat: 'ENERGIZANTES', kw: ['ENERGY DRINK','GATORADE','GENERADE','POWERADE','SPORADE','VOLT ENERGY'] },
  { cat: 'VINOS_LICORES', kw: ['PISCO','VINO BLANCO','VINO TINTO','VINO MISTELA','VINO OPORTO','VINO SUELTO','GATO VINO','MITJANS','HUA TIAO','VINO DE ARROZ','LICOR DE ALMENDRAS'] },
  { cat: 'CONSERVAS', kw: ['ATUN','DURAZNO EN ALMIB','DURAZNO MITAD','DURAZNO EN MITADES','PIÑA EN RODAJA','CHAMPIÑON','ALCAPARRA','CEREZAS MARRA','ALMIBAR DE DURAZNO','TROZOS DE ATUN'] },
  { cat: 'ACEITES', kw: ['ACEITE VEGETAL','ACEITE OLIVA','ACEITE DE OLIVA','ACEITE DE AJONJOLI','ACEITE DE COCO','ACEITE SACHA','ACEITE DE ALMENDRA','ACEITE DE OREGANO','ACEITE DE ROMERO','ACEITE 500ML','ACEITE 900ML','ACEITE 1L','ACEITE 5L','ACEITE 18LT'] },
  { cat: 'VINAGRES', kw: ['VINAGRE'] },
  { cat: 'PRODUCTOS_CHINOS', kw: ['PANCO','FIDEO DE ARROZ','FIDEO DE CAMOTE','PASTA WANTAN','WANTAN','LASAGNA','ALGA NORI','DASHI','SICHIMI','TOGARASHI','PAPEL DE ARROZ','HOJUELAS DE CAMARON','ARROZ GLUTINOSO','WASABI','NANAMI','ARROZ GLUTI'] },
  { cat: 'SALSAS', kw: ['MAYONESA','KETCHUP','MOSTAZA','SALSA','SILLAO','SHOYU','SHIRACHA','SRIRACHA','TAUSI','TAMARINDO','AJOIKION','AJOSIBA','POMAROLA','CONCENTRADO DE TOMATE','CREMA DE AJI','CREMA DE ROCOTO','PREPARADO ORIENTAL','PREPARADO ARROZ CHAUFA','PREPARADO LOMO','PREPARADO TALLARIN','PREPARADO LECHON','PREPARADO PACHAMANCA','PREPARADO PAVO','PREPARADO POLLO A LA BRASA','PREPARADO OSTION','AMARILLIN','CULANTRIN','CULANTRITO','PANQUITA','TUCO TALLARIN','AJI PANCA CON PIM','BARBACOA','HOI-SIN','HOI SIN','AJINOSILLAO','MANJAR DE LECHE','SAZONADOR HUMO LIQUIDO','MARINADO','TERIYAKI','KIKKOMAN','CHEKETUP','MENSI'] },
  { cat: 'CONFITERIA', kw: ['CHUPETIN','CARAMELO','ALPENLIEBE','HONG YUAN','WHITE RABBIT','TRIDENT','CHOCO CHOCKY','DELICIOUS JALEA','SUMIYAKI'] },
  { cat: 'GALLETAS_SNACKS', kw: ['GALLETA','OREO','CHOCMAN','FRAC ','NIK ','WAFER','CUA CUA','CUATES','CHOCO DONUTS','CORONITA','CANCUN','CHOCO BUM','DOÑA PEPA','TENTACION','PICARAS','GLACITAS','MOROCHAS','CHICHARRON','CHIFLES','PAPAS FRITAS','CARAVANA','BARRA MANJAR','BARRA FRUTOS','MERENFRESA','PACIENCIA','REDONDITO ALFAJOR','ANTOJO GALLETA','CHOCOTEJA','PIQUEO','SODA ','BISCOCHO','CHIPS','VAINIYA','CACHITO','HOJARASA','TAPITAS','GALLETERA'] },
  { cat: 'INSUMOS_REPOSTERIA', kw: ['MOLDE','CORTADOR','MANGA PASTELERA','MANGA DE SILICONA','MANGAS REPOSTERA','MANGA DE TEFLON','BOQUILLA','PINCEL','ESPATULA','ESTECA','RASPADOR','PORCIONADOR','PULSADOR','RODILLO CORTADOR','TEXTURIZADOR','PALETA DE SILICONA','CAKE TOOL','ALAMBRE PARA FLORES','BAILARINA','MOLEDOR DE PIMIENTA','AEROGRAFO','AERO GRAFO','ALISADOR','JUEGO DE BOQUILLA','SET DE BOQUILLAS','PLUNGER','SCANNCUT','PEGAMENTO REPOSTERO','IMPRESION EN PAPEL','CONTOMETRO','CONDIMENTERO','BROCHA','SET DE CORTADORES','DISPENSADOR','SELLO ALFAB','RODILLO'] },
  { cat: 'DECORATIVOS', kw: ['TECNOPOR','MARIPOSA','TOPPER','TOPER','BASE 10','BASE 15','BASE 25','BASE 30','BASE 35','BASE 40','BASE DE ','BASE CUADRADA','BASE RECTANGULAR','BASE 34','MAQUETA','CORONA DE CERAMICA','BOTELLA DECORATIVA','SILUETA','CINTA TELA','CINTA SATINADA','PAPEL PIROTIN','PIROTIN','CAÑITA DE PAPEL','MINI TAPETE','ESFERA DE PLASTICO','ESFERA DE TECNOPOR','PAPEL ORO COMESTIBLE','BRILLO MULTICOLOR','VELA','CORTE DECORATIVO','BANDEJA REDONDA PARA BOCADITO','PERLAS','PERLA CONTINUA','MOLDADIENTES','MONDA DIENTE'] },
  { cat: 'DESCARTABLES', kw: ['BANDEJA','CAJA','BOLSA','PLATO DESCARTABLE','VASO DESCARTABLE','VASO ACRILICO','CUBIERTO','CELOFAN','CEOFAN','ENVASE DE PLASTICO','ENVASE PB','ENVASE PET','ENVASE TRANSPARENTE','ENVOLTURA','KOPAS VASOS','DOMO NUMERO','MASCARILLA AZUL','SERVILLETA','MINI TENEDOR','CUCHARITA DE PLASTICO','SORBETON','PALITO','PAPEL MANTECA','PAPEL FOTO','PAPEL HIGIENICO','PAPEL TOALLA','PALILLOS CHINOS','CINTA DE EMBALAJE','CINTA TAPE','BANDEJA DESCARTABLE','PLATO HONDO'] },
  { cat: 'LIMPIEZA', kw: ['DETERGENTE','JABON','LAVA VAJILLA','LAVAVAJILLAS','BLANQUEADOR','CLOROX','AYUDIN','LIMPIATODO','NORMITA','SAPOLIO','DKASA','GALLO REPELENTE','SICARIO MATA RATAS','SHAMPOO','JABON LIQUIDO'] },
  { cat: 'ENDULZANTES', kw: ['PANELA','CHANCACA','ALGARROBINA','AZUCAR','MIEL ','ABEJA REAL','ABEJITA','OBRERA MIEL','REAL COLMENA','SAHENA MIEL','MIEL ECO'] },
  { cat: 'LACTEOS', kw: ['LECHE EVAPORADA','LECHE CONDENSADA','LECHE UHT','LECHE SIN LACTOSA','LECHE LIGHT','LECHE ZERO','LECHE AMANECER','LECHE CREMOSITA','LECHE EN POLVO','CREMA DE LECHE','QUESO PARMESANO','QUESO CREMA','CHANTILLY','MANJAR BLANCO','MANTEQUILLA','MARGARINA','CHOCOLATADA','MANTECA HIDROGENADA','FAMOSA MANTECA','NESTLE MANJAR','NESTLE LECHE','NESTLE CREMA','NESTLE TOPPING','BONLE'] },
  { cat: 'REPOSTERIA', kw: ['COBERTURA','FONDANT','PASTA DE GOMA','MASA ELASTICA','MASA FONDANT','ESENCIA','ESCENCIA','COLORANTE','GLUCOSA','NACAR','BRILLO ','CMC','GOMA TRAGACANTO','DISCO COMESTIBLE','CHOCOLATE','COCOA','CHISPAS','OBLEAS','FUDGE','PAPEL ORO','MERMELADA','PIONONO','KEKE','GRAJEA','GELATINA','FLAN','PUDIN','PASTA PURA','CACAO','COCO RALLADO','ALMENDRA EN POLVO','NUEZ MOSCADA EN POLVO','POLVO DE HORNEAR','CREMOR TARTARO','COLAPIZ','BICARBONATO','CHEESECUPCAKE','CHOCO CUPCAKE','CANDY FRUIT','JALEA BEBIBLE','DESMOLDANTE','ESTABILIZADOR','CHUÑO','ALMIDON DE YUCA','FECULA DE PAPA','HARINA DE MAIZ','MAIZENA','GALLETA MOLIDA','PAN BLANCO MOLIDO','PAN MOLIDO OSCURO','MAZAMORRA','MATCHA','MELOSITA','AZUCAR IMPALPABLE','STAR CHEMICAL','PASTELILLO','GALLETA CONO','TOPPING CONDENSADA','JOFSAC','TESORO QUILLABAMBA','SOL DE ICA','SOL DEL CUZCO','PAN HARINA DE MAIZ','C.M.C.'] },
  { cat: 'ESPECIAS', kw: ['PIMIENTA','COMINO','CANELA','CLAVO DE OLOR','OREGANO','ROMERO','TOMILLO','ANIS','CARDOMOMO','NUEZ MOSCADA','AZAFRÁN','AZAFRAN','PALILLO','KION','CURCUMA','ACHIOTE','AJI PANCA POLVO','AJI PANCA EN POLVO','AJI POLVO','PAPRICA','PAPRIKA','AJO EN POLVO','AJO POLVO','CEBOLLA POLVO','CEBOLLA EN POLVO','ENELDO','ESTRAGON','MEJORANA','SALVIA','HIERBAS FINAS','HONGO Y LAUREL','LAUREL','HOJA LAUREL','CULANTRO','CURRY','GARAM MASALA','HERBES DE PROVENCE','JENGIBRE','SAL DE APIO','SAZON COMPLETA','SAZONADOR','HONGO ','SARTA','SIBARITA','MOLINO VIEJO','BADIA'] },
  { cat: 'MENESTRAS', kw: ['FRIJOL','LENTEJA','LENTEJON','GARBANZO','PALLAR','PANAMITO','ARVERJA','MORON','MAIZ MOTE','MAIZ CHULPI','MAIZ PILPE','MAIZ ASTILLA','MAIZ BLANCO','POP CORN'] },
  { cat: 'GRANEL', kw: ['GRANEL','ALMENDRA','NUEZ ENTERA','PISTACHO','CASTAÑA','MANI','PASA','GUINDON','GUINDA','DAMASCO','DATILES','HIGO DESHIDRATADO','ARANDANO DESHIDRATADO','AJONJOLI','CHIA','LINAZA','KIWICHA','QUINUA','SEMILLA DE GIRASOL','SEMILLA DE CALABAZA','MACA','CAÑIHUA','OREJON','HUESILLO','CHARQUI','CAMARON SECO','CAMARON DESHIDRATADO','HARINA DE MACA','HARINA DE LINAZA','HARINA DE AJONJOLI','HARINA DE SACHA','HARINA TOCOSH','HARINA CURCUMA','AVENA EN HOJUELA','CEBADA TOSTADA','TRIGO ENTERO','FLOR DE JAMAICA','SIETE SEMILLAS','SALVADO DE TRIGO','GERMEN DE TRIGO','CASCARA DE CACAO','NATURAL MAXX','SUR ANDINO','HARINA DE MAIZ NEGRA'] },
  { cat: 'BEBIDAS', kw: ['GASEOSA','COCA COLA','INCA KOLA','FANTA','PEPSI','KR ','KRIS ','ORO GASEOSA','KERO','FRUVI','FRUGO','DEL VALLE FRESH','AGUA','BEBIDA','CAFE','CHOCOLATADA GLORIA','CIELO','LOA AGUA','PURA VIDA AGUA','ZUKO','UMSHA REFRESCO','CHICHA','EMOLIENTE','BAIXIANG BEBIDA','REFRESCO'] },
  { cat: 'ABARROTES', kw: ['HARINA','FIDEO','ARROZ','AVENA','SAL ','GLUTAMATO','NAKAMITO','AJINOMOTO','AJINOMIX','AJINOMEN','PETER PAN','MANTEQUILLA DE MANI','CHICKEN POWDER','NORSAL','EMSAL','CORESA SAL','SAMBER','HOJA VERDE','SAL DE LOS ANDES','BIOSELVA SAL','LOTUS GLUTAMATO','TRIGAL','INCA HARINA','NUTRIMIX','RED & WHITE','SEMOLA','SEMILLAS DE QUILLABAMBA','BAKELS','LEVADURA','DOÑA GUSTA','DOS BANDERAS','MAGGI','KNORR','HARINA PREPARADA','HARINA SIN PREPARAR','MOLITALIA','NICOLINI','MAXIMO','FAVORITA','BLANCA FLOR','SANTA CATALINA','QUAKER','HUEVO'] }
];

function _clasificarProducto(descripcionUpper) {
  for (var i = 0; i < _CLASIFICADOR_REGLAS.length; i++) {
    var regla = _CLASIFICADOR_REGLAS[i];
    for (var j = 0; j < regla.kw.length; j++) {
      if (descripcionUpper.indexOf(regla.kw[j]) >= 0) return regla.cat;
    }
  }
  return 'OTROS';
}

// Crea las categorías iniciales si no existen. Idempotente.
function _crearCategoriasIniciales() {
  var sheet = _garantizarHojaCategorias();
  var existentes = _sheetToObjects(sheet);
  var idsExistentes = {};
  existentes.forEach(function(c) { idsExistentes[String(c.idCategoria || '').toUpperCase()] = true; });

  var nuevasFilas = [];
  _CATEGORIAS_INICIALES.forEach(function(cat) {
    if (idsExistentes[cat.id.toUpperCase()]) return;
    nuevasFilas.push([
      cat.id, cat.nombre, 'MARGEN', cat.margenPct, '', cat.descripcion, 1, new Date()
    ]);
  });

  if (nuevasFilas.length) {
    sheet.getRange(sheet.getLastRow() + 1, 1, nuevasFilas.length, MOS_HEADERS.CATEGORIAS.length)
         .setValues(nuevasFilas);
  }
  return nuevasFilas.length;
}

// Función masiva: clasifica canónicos, normaliza unidades, marca régimen EXO.
// Idempotente: respeta lo que ya existe (no sobreescribe idCategoria existente,
// sí actualiza unidades a KGM/NIU si difieren, sí marca EXO si descripción lo dice).
function migrarCatalogoCompleto() {
  // 1. Crear categorías + garantizar columnas
  var creadas = _crearCategoriasIniciales();
  _garantizarColumnasPoliticaProductos();

  // 2. Leer toda la hoja PRODUCTOS_MASTER
  var sheet = getSheet('PRODUCTOS_MASTER');
  var data  = sheet.getDataRange().getValues();
  var hdrs  = data[0];

  var col = {
    idProducto: hdrs.indexOf('idProducto'),
    skuBase: hdrs.indexOf('skuBase'),
    codigoBarra: hdrs.indexOf('codigoBarra'),
    descripcion: hdrs.indexOf('descripcion'),
    idCategoria: hdrs.indexOf('idCategoria'),
    unidad: hdrs.indexOf('unidad'),
    Unidad_Medida: hdrs.indexOf('Unidad_Medida'),
    esEnvasable: hdrs.indexOf('esEnvasable'),
    codigoProductoBase: hdrs.indexOf('codigoProductoBase'),
    factorConversion: hdrs.indexOf('factorConversion'),
    Cod_Tributo: hdrs.indexOf('Cod_Tributo'),
    IGV_Porcentaje: hdrs.indexOf('IGV_Porcentaje'),
    Tipo_IGV: hdrs.indexOf('Tipo_IGV')
  };

  // Construir filas + identificar canónicos
  var filas = [];
  var canonicosByIdProducto = {};
  var canonicosBySkuBase    = {};

  for (var i = 1; i < data.length; i++) {
    var row = data[i];
    var prod = {
      rowIdx:           i + 1,
      idProducto:       String(row[col.idProducto] || ''),
      skuBase:          String(row[col.skuBase] || ''),
      codigoBarra:      String(row[col.codigoBarra] || ''),
      descripcion:      String(row[col.descripcion] || ''),
      idCategoria:      String(row[col.idCategoria] || '').trim(),
      unidad:           String(row[col.unidad] || ''),
      Unidad_Medida:    String(row[col.Unidad_Medida] || ''),
      esEnvasable:      String(row[col.esEnvasable] || '0'),
      codigoProductoBase: String(row[col.codigoProductoBase] || '').trim(),
      factorConversion: row[col.factorConversion],
      Cod_Tributo:      String(row[col.Cod_Tributo] || ''),
      IGV_Porcentaje:   row[col.IGV_Porcentaje],
      Tipo_IGV:         String(row[col.Tipo_IGV] || '')
    };
    if (!prod.idProducto && !prod.codigoBarra && !prod.descripcion) continue; // fila vacía
    prod.esCanonico = _esCanonico({
      codigoProductoBase: prod.codigoProductoBase,
      factorConversion:   prod.factorConversion
    });
    filas.push(prod);
    if (prod.esCanonico) {
      if (prod.idProducto) canonicosByIdProducto[prod.idProducto.toUpperCase()] = prod;
      if (prod.skuBase)    canonicosBySkuBase[prod.skuBase.toUpperCase()]       = prod;
    }
  }

  var stats = {
    categoriasCreadas: creadas,
    canonicos: 0,
    canonicosClasificados: 0,
    canonicosYaTeniaCat: 0,
    canonicosOtros: [],
    presentaciones: 0,
    derivados: 0,
    unidadActualizada: 0,
    canonicosExo: 0,
    fiscalPropagado: 0
  };

  // PASADA A: canónicos
  filas.forEach(function(prod) {
    if (!prod.esCanonico) return;
    stats.canonicos++;

    var desc = prod.descripcion.toUpperCase();

    // A1. Clasificar idCategoria si está vacío
    if (!prod.idCategoria) {
      var cat = _clasificarProducto(desc);
      var rg = sheet.getRange(prod.rowIdx, col.idCategoria + 1);
      rg.setNumberFormat('@STRING@').setValue(cat);
      prod.idCategoria = cat;
      stats.canonicosClasificados++;
      if (cat === 'OTROS') stats.canonicosOtros.push(prod.idProducto + ' · ' + prod.descripcion);
    } else {
      stats.canonicosYaTeniaCat++;
    }

    // A2. Limpiar unidad: KGM si granel/envasable, NIU si no
    var esGranel = String(prod.esEnvasable) === '1' || desc.indexOf('GRANEL') >= 0;
    var unidadEsperada = esGranel ? 'KGM' : 'NIU';
    if (prod.unidad !== unidadEsperada || prod.Unidad_Medida !== unidadEsperada) {
      sheet.getRange(prod.rowIdx, col.unidad + 1).setValue(unidadEsperada);
      sheet.getRange(prod.rowIdx, col.Unidad_Medida + 1).setValue(unidadEsperada);
      prod.unidad = unidadEsperada;
      prod.Unidad_Medida = unidadEsperada;
      stats.unidadActualizada++;
    }

    // A3. Régimen EXO si descripción lo indica
    if (desc.indexOf('EXO') >= 0) {
      sheet.getRange(prod.rowIdx, col.Cod_Tributo + 1).setValue('9997');
      sheet.getRange(prod.rowIdx, col.Tipo_IGV + 1).setValue('2');
      sheet.getRange(prod.rowIdx, col.IGV_Porcentaje + 1).setValue(0);
      prod.esExo = true;
      stats.canonicosExo++;
    }
  });

  // PASADA B: presentaciones y derivados
  filas.forEach(function(prod) {
    if (prod.esCanonico) return;

    // Buscar canónico
    var canonico = null;
    if (prod.codigoProductoBase) {
      canonico = canonicosByIdProducto[prod.codigoProductoBase.toUpperCase()] ||
                 canonicosBySkuBase[prod.codigoProductoBase.toUpperCase()];
      stats.derivados++;
    } else if (prod.skuBase) {
      canonico = canonicosBySkuBase[prod.skuBase.toUpperCase()];
      stats.presentaciones++;
    }

    // Las presentaciones empacadas siempre van en NIU (se venden por unidad)
    if (prod.unidad !== 'NIU' || prod.Unidad_Medida !== 'NIU') {
      sheet.getRange(prod.rowIdx, col.unidad + 1).setValue('NIU');
      sheet.getRange(prod.rowIdx, col.Unidad_Medida + 1).setValue('NIU');
      stats.unidadActualizada++;
    }

    // Si su canónico es EXO → propagar régimen
    if (canonico && canonico.esExo) {
      sheet.getRange(prod.rowIdx, col.Cod_Tributo + 1).setValue('9997');
      sheet.getRange(prod.rowIdx, col.Tipo_IGV + 1).setValue('2');
      sheet.getRange(prod.rowIdx, col.IGV_Porcentaje + 1).setValue(0);
      stats.fiscalPropagado++;
    }
  });

  Logger.log('Migración masiva completada: ' + JSON.stringify(stats, null, 2));
  return { ok: true, data: stats };
}
