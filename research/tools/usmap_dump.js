const fs = require('fs');

const path = require('path');
const b = fs.readFileSync(path.join(__dirname, '..', 'data', 'full.usmap'));
let off = 16;
const nameCount = b.readUInt32LE(off); off += 4;
const names = [];
for (let i = 0; i < nameCount; i++) {
  const len = b.readUInt16LE(off); off += 2;
  names.push(b.toString('utf8', off, off + len)); off += len;
}

const PT = ['ByteProperty','BoolProperty','IntProperty','FloatProperty','ObjectProperty','NameProperty','DelegateProperty','DoubleProperty','ArrayProperty','StructProperty','StrProperty','TextProperty','InterfaceProperty','MulticastDelegateProperty','WeakObjectProperty','LazyObjectProperty','AssetObjectProperty','SoftObjectProperty','UInt64Property','UInt32Property','UInt16Property','Int64Property','Int16Property','Int8Property','MapProperty','SetProperty','EnumProperty','FieldPathProperty','OptionalProperty','Utf8StrProperty','AnsiStrProperty','ClassProperty','MulticastInlineDelegateProperty','SoftClassProperty','VerseStringProperty','VerseDynamicProperty','VerseFunctionProperty'];

function readName() {
  const idx = b.readInt32LE(off); off += 4;
  return idx === -1 ? null : names[idx];
}

function readType() {
  const t = b[off++];
  let structType = null, inner = null, value = null, enumName = null;
  switch (t) {
    case 26: inner = readType(); enumName = readName(); break;
    case 9: structType = readName(); break;
    case 8: case 25: case 28: inner = readType(); break;
    case 24: inner = readType(); value = readType(); break;
  }
  return { t: PT[t] || ('T' + t), structType, inner, value, enumName };
}

const enumCount = b.readUInt32LE(off); off += 4;
const enums = [];
for (let i = 0; i < enumCount; i++) {
  const name = readName();
  const count = b.readUInt16LE(off); off += 2;
  const values = [];
  for (let j = 0; j < count; j++) {
    const v = b.readBigUInt64LE(off); off += 8;
    const vn = readName();
    values.push([Number(v), vn]);
  }
  enums.push({ name, values });
}

const structCount = b.readUInt32LE(off); off += 4;
const structs = [];
for (let i = 0; i < structCount; i++) {
  const name = readName();
  const superName = readName();
  const propertyCount = b.readUInt16LE(off); off += 2;
  const serCount = b.readUInt16LE(off); off += 2;
  const props = [];
  for (let j = 0; j < serCount; j++) {
    const index = b.readUInt16LE(off); off += 2;
    const arrayDim = b[off]; off += 1;
    const pname = readName();
    const type = readType();
    props.push({ index, arrayDim, name: pname, type });
  }
  structs.push({ name, superName, propertyCount, props });
}

console.error('enums', enums.length, 'structs', structs.length, 'end', off, 'file', b.length);

function typeStr(t) {
  switch (t.t) {
    case 'EnumProperty': return 'Enum<' + t.enumName + '(' + typeStr(t.inner) + ')>';
    case 'StructProperty': return 'Struct<' + t.structType + '>';
    case 'ArrayProperty': return typeStr(t.inner) + '[]';
    case 'SetProperty': return 'Set<' + typeStr(t.inner) + '>';
    case 'OptionalProperty': return 'Optional<' + typeStr(t.inner) + '>';
    case 'MapProperty': return 'Map<' + typeStr(t.inner) + ',' + typeStr(t.value) + '>';
    default: return t.t;
  }
}

const out = [];
out.push('# ENUMS');
for (const e of enums) out.push(e.name + ' = ' + e.values.map(v => v[1] + (v[0] !== 0 ? '(' + v[0] + ')' : '')).join(' | '));
out.push('');
out.push('# STRUCTS/CLASSES');
for (const s of structs) {
  out.push(s.name + (s.superName ? ' : ' + s.superName : '') + ' {');
  for (const p of s.props) out.push('  ' + p.name + ' : ' + typeStr(p.type) + (p.arrayDim > 1 ? '[' + p.arrayDim + ']' : ''));
  out.push('}');
}
fs.writeFileSync(path.join(__dirname, '..', 'data', 'schema.txt'), out.join('\n'), 'utf8');
fs.writeFileSync(path.join(__dirname, '..', 'data', 'schema.json'), JSON.stringify({ enums, structs }), 'utf8');
