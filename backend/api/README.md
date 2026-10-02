Files in `swaggerui/`: Swagger UI 5.33.1 (`swagger-ui-dist`, Apache-2.0; see LICENSE and NOTICE).

Only the files the docs page needs are kept here, embedded into the `tarkd`
binary so the docs work without reaching a CDN. To update:

    npm pack swagger-ui-dist
    tar xzf swagger-ui-dist-*.tgz
    cp package/{swagger-ui-bundle.js,swagger-ui.css,favicon-32x32.png,LICENSE,NOTICE,swagger-ui-bundle.js.LICENSE.txt} backend/api/swaggerui/

`index.html` and `swagger-initializer.js` are ours.
