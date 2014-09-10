var path = require('path')
var child_process = require('child_process')

var options = {cwd: path.join(__dirname, '..')}
var updateCommand = 'npm update grunt-atomdoc'
var docCommand = 'grunt clean lint coffee atomdoc'
child_process.exec(updateCommand, options, function(error, stdout, stderr) {
  if(stderr) console.error(stderr);
  child_process.exec(docCommand, options, function(error, stdout, stderr) {
    if(stderr) console.error(stderr);
  })
})
