from net.http import Request, ResponseWriter, ServeMux


def _item(req: Request, mut writer: ResponseWriter) raises:
    writer.headers.add("X-Query", req.query.copy())
    writer.write_string(ServeMux.param(req, "id").value())


def _literal(req: Request, mut writer: ResponseWriter) raises:
    writer.write_string("literal")


def _rest(req: Request, mut writer: ResponseWriter) raises:
    writer.write_string(ServeMux.param(req, "path").value())


def _echo(req: Request, mut writer: ResponseWriter) raises:
    writer.write(Span(req.body))


def router_contract() raises -> ServeMux:
    var mux = ServeMux()
    mux.handle("GET /router/items/{id}", _item)
    mux.handle("GET /router/items/fixed", _literal)
    mux.handle("GET /router/static/{path...}", _rest)
    mux.handle("POST /router/echo", _echo)
    return mux^
