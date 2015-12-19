path = require('path')
fs = require('fs')

module.exports = fs.readFileSync(path.join(__dirname, '..', 'fixtures', 'sample.js'), 'utf8')
