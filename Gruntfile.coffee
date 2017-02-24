module.exports = (grunt) ->
  grunt.initConfig
    pkg: grunt.file.readJSON('package.json')

    shell:
      test:
        command: 'node node_modules/.bin/jasmine-focused --coffee --captureExceptions --forceexit spec'
        options:
          stdout: true
          stderr: true
          failOnError: true

      'update-atomdoc':
        command: 'npm update grunt-atomdoc donna tello atomdoc'
        options:
          stdout: true
          stderr: true
          failOnError: true

  grunt.loadNpmTasks('grunt-shell')
  grunt.loadNpmTasks('grunt-atomdoc')

  grunt.registerTask 'clean', ->
    require('rimraf').sync('lib')
    require('rimraf').sync('api.json')

  grunt.registerTask('test', ['shell:test'])
