local greeting = require("modules.greeting")
print(greeting.message())
print(assert(lcb.read("assets/message.txt")))
print("Runtime: " .. _VERSION)
print("Arguments: " .. #arg)
for i = 1, #arg do print(i, arg[i]) end
return 0
