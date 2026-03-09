


# Delta release dependency matrix constructure

## source file --> libraries/binaries
> produce dependency matix

### c/c++ project
> gcc + script parse
- solution: bear/compile_commands.json
  - need import third-party tool and more scirpt work
- solution: gcc (.d file)
  - prouduce compilation and link dependency automatically, better compatibility
  - separate dependency json file to keep make parallel task available
  - need common **script** to parse all dependency file to construct whole project dependency view.

- maintenance recommendations
  - (.h/.c/.cxx/.cpp/.hpp - .o): once parsing rule is created, no need for manual maintenance generally
  - (.o - .so/bin): the linked file needs to be accurate in build system, the linked file should be indeed used in binary/library


### go project
> go + script parse

- solution:
  parse output of `go list -json <path>` to construct dependency between go file and libraries/binaries.

- maintenance recommendations
  - (.go - .so/bin): if go project location change , our scirpt need be changed accordingly.

### java project
> script parse

- build by maven/grave
  - parse pod.xml to consturct dependency matrix
- build by javac
  TODO: use manual configu dependency matrix

- maintenance recommendations
  - (.java - .jar) by maven: once parsing rule is created, no need for manual maintenance generally
  - (.java - .jar) by javac: todo

## libraries/binaries + plain text  --> rpm
> script parse

- solution:
  parse rpm build config file (ComponentDescription.xml)

- maintenance recommendations
  - (.so/bin/text - rpm): once parsing rule is created, no need for manual maintenance generally

## rpm + plain text --> image
> script parse

- solution:
  parse dockerfile

- maintenance recommendations
  - (.so/bin/text - rpm): once parsing rule is created, no need for manual maintenance generally

## plain text --> image

 read installGuide.in


## image/charts version managerment
> TODO: discuss with SCM





