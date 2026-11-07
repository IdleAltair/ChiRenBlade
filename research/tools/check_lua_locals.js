const fs = require('fs');
const luaparse = require('E:/tmp/luaparse/node_modules/luaparse');

const code = fs.readFileSync(process.argv[2] || 'main.lua', 'utf8');
const ast = luaparse.parse(code, { luaVersion: '5.3', locations: true });

let maxSeen = { n: 0, line: 0, name: '' };
let errors = [];

function note(n, line, where) {
    if (n > maxSeen.n) maxSeen = { n, line, name: where };
    if (n > 200) errors.push({ n, line, where });
}

function walkExpr(node, active, where) {
    if (!node || typeof node !== 'object') return;
    if (Array.isArray(node)) { node.forEach((n) => walkExpr(n, active, where)); return; }
    if (node.type === 'FunctionDeclaration' || node.type === 'FunctionExpression') {
        const params = (node.parameters || []).reduce((a, p) => a + (p.type === 'VarargLiteral' ? 0 : 1), 0);
        walkBlock(node.body, params, where + ':fn@' + (node.loc ? node.loc.start.line : '?'));
        return;
    }
    for (const key of Object.keys(node)) {
        if (key === 'loc' || key === 'range') continue;
        walkExpr(node[key], active, where);
    }
}

function walkBlock(stmts, initialActive, where) {
    let active = initialActive;
    for (const stmt of stmts) {
        if (!stmt) continue;
        const line = stmt.loc ? stmt.loc.start.line : 0;
        if (stmt.type === 'LocalStatement') {
            active += stmt.variables.length;
            note(active, line, where + ':local ' + stmt.variables.map((v) => v.name).join(','));
            stmt.init.forEach((e) => walkExpr(e, active, where));
        } else if (stmt.type === 'FunctionDeclaration') {
            if (stmt.isLocal) {
                active += 1;
                note(active, line, where + ':local function ' + stmt.identifier.name);
            } else {
                walkExpr(stmt.identifier, active, where);
            }
            const params = (stmt.parameters || []).reduce((a, p) => a + (p.type === 'VarargLiteral' ? 0 : 1), 0);
            walkBlock(stmt.body, params, where + ':fn ' + (stmt.isLocal ? stmt.identifier.name : '?'));
        } else if (stmt.type === 'DoStatement') {
            walkBlock(stmt.body, active, where + ':do@' + line);
        } else if (stmt.type === 'WhileStatement') {
            walkExpr(stmt.condition, active, where);
            walkBlock(stmt.body, active, where + ':while@' + line);
        } else if (stmt.type === 'RepeatStatement') {
            walkBlock(stmt.body, active, where + ':repeat@' + line);
            walkExpr(stmt.condition, active, where);
        } else if (stmt.type === 'IfStatement') {
            stmt.clauses.forEach((clause) => {
                walkExpr(clause.condition, active, where);
                walkBlock(clause.body, active, where + ':if@' + line);
            });
        } else if (stmt.type === 'ForNumericStatement') {
            walkExpr(stmt.start, active, where);
            walkExpr(stmt.end, active, where);
            walkExpr(stmt.step, active, where);
            walkBlock(stmt.body, active + 1, where + ':for@' + line);
        } else if (stmt.type === 'ForGenericStatement') {
            stmt.iterators.forEach((e) => walkExpr(e, active, where));
            walkBlock(stmt.body, active + stmt.variables.length, where + ':forin@' + line);
        } else {
            walkExpr(stmt, active, where);
        }
    }
}

walkBlock(ast.body, 0, 'main');
console.log('peak active locals in main chunk:', maxSeen.n, 'at line', maxSeen.line, '(' + maxSeen.name + ')');
if (errors.length) {
    console.log('OVER LIMIT events:', errors.length);
    errors.slice(0, 10).forEach((e) => console.log(' ', e.n, 'line', e.line, e.where));
    process.exit(2);
}
console.log('OK: under 200');
