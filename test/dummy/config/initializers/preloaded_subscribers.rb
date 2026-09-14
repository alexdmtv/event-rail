# Plainly required, before application preparation, from outside any autoload root.
# This is the supported way to declare a subscriber Zeitwerk does not manage, and the
# fixture exists to prove preparation includes it and every rebuild keeps it.
#
# Initializers run before Rails sets up the main autoloader, so non-reloadable code
# cannot reference autoloaded constants: this file brings its own event class and its
# own job base rather than inheriting from the application's.
require Rails.root.join("preloaded/preloaded/order_audit_job")
