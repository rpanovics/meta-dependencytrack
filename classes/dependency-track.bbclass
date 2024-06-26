# SPDX-License-Identifier: MIT
# Copyright 2022 BG Networks, Inc.

# The product name that the CVE database uses.  Defaults to BPN, but may need to
# be overriden per recipe (for example tiff.bb sets CVE_PRODUCT=libtiff).
CVE_PRODUCT ??= "${BPN}"
CVE_VERSION ??= "${PV}"

DEPENDENCYTRACK_DIR ??= "${DEPLOY_DIR}/dependency-track"
DEPENDENCYTRACK_SBOM ??= "${DEPENDENCYTRACK_DIR}/bom.json"
DEPENDENCYTRACK_TMP ??= "${TMPDIR}/dependency-track"
DEPENDENCYTRACK_LOCK ??= "${DEPENDENCYTRACK_TMP}/bom.lock"

# Set DEPENDENCYTRACK_UPLOAD to False if you want to control the upload in other
# steps.
DEPENDENCYTRACK_UPLOAD ??= "False"
DEPENDENCYTRACK_PROJECT ??= ""
DEPENDENCYTRACK_API_URL ??= "http://localhost:8081/api"
DEPENDENCYTRACK_API_KEY ??= ""
DEPENDENCYTRACK_PROJECT_NAME ??= ""
DEPENDENCYTRACK_PROJECT_VERSION ??= ""
DEPENDENCYTRACK_PARENT ??= ""
DEPENDENCYTRACK_PARENT_NAME ??= ""
DEPENDENCYTRACK_PARENT_VERSION ??= ""
DEPENDENCYTRACK_AUTO_CREATE ??= "false"

DT_LICENSE_CONVERSION_MAP ??= '{ "GPLv2+" : "GPL-2.0-or-later", "GPLv2" : "GPL-2.0", "LGPLv2" : "LGPL-2.0", "LGPLv2+" : "LGPL-2.0-or-later", "LGPLv2.1+" : "LGPL-2.1-or-later", "LGPLv2.1" : "LGPL-2.1"}'

python do_dependencytrack_init() {
    import uuid
    from datetime import datetime, timezone

    sbom_dir = d.getVar("DEPENDENCYTRACK_DIR")
    if not os.path.exists(sbom_dir):
        bb.debug(2, "Creating cyclonedx directory: %s" % sbom_dir)
        bb.utils.mkdirhier(sbom_dir)
        bb.debug(2, "Creating empty sbom")
        write_sbom(d, {
            "bomFormat": "CycloneDX",
            "specVersion": "1.5",
            "serialNumber": "urn:uuid:" + str(uuid.uuid4()),
            "version": 1,
            "metadata": {
                "timestamp": datetime.now(timezone.utc).isoformat(),
            },
            "components": []
        })
}
addhandler do_dependencytrack_init
do_dependencytrack_init[eventmask] = "bb.event.BuildStarted"

python do_dependencytrack_collect() {
    import json
    from pathlib import Path

    # load the bom
    name = d.getVar("CVE_PRODUCT")
    version = d.getVar("CVE_VERSION")
    sbom = read_sbom(d)

    # update it with the new package info

    for index, o in enumerate(get_cpe_ids(name, version)):
        bb.debug(2, f"Collecting package {name}@{version} ({o.cpe})")
        if not next((c for c in sbom["components"] if c["cpe"] == o.cpe), None):
            
            component_json = {
                "type": "application",
                "name": o.product,
                "group": o.vendor,
                "version": version,
                "cpe": o.cpe,
            }
            
            license_json = get_licenses(d)
            if license_json:
                component_json["licenses"] = license_json
            sbom["components"].append(component_json)

    # write it back to the deploy directory
    write_sbom(d, sbom)
}

addtask dependencytrack_collect before do_build after do_fetch
do_dependencytrack_collect[nostamp] = "1"
do_dependencytrack_collect[lockfiles] += "${DEPENDENCYTRACK_LOCK}"
do_rootfs[recrdeptask] += "do_dependencytrack_collect"

python do_dependencytrack_upload () {
    import json
    import base64
    import requests
    from pathlib import Path

    dt_upload = bb.utils.to_boolean(d.getVar('DEPENDENCYTRACK_UPLOAD'))
    if not dt_upload:
        return

    sbom_path = d.getVar("DEPENDENCYTRACK_SBOM")
    dt_project = d.getVar("DEPENDENCYTRACK_PROJECT")
    dt_url = f"{d.getVar('DEPENDENCYTRACK_API_URL')}/v1/bom"
    dt_project_name = d.getVar("DEPENDENCYTRACK_PROJECT_NAME")
    dt_project_version = d.getVar("DEPENDENCYTRACK_PROJECT_VERSION")
    dt_parent = d.getVar("DEPENDENCYTRACK_PARENT")
    dt_parent_name = d.getVar("DEPENDENCYTRACK_PARENT_NAME")
    dt_parent_version = d.getVar("DEPENDENCYTRACK_PARENT_VERSION")
    dt_auto_create = d.getVar("DEPENDENCYTRACK_AUTO_CREATE")

    bb.debug(2, f"Loading final SBOM: {sbom_path}")
    bb.debug(2, f"Uploading SBOM to project {dt_project} at {dt_url}")

    headers = {
        "X-API-Key": d.getVar("DEPENDENCYTRACK_API_KEY")
    }

    files = {
        'autoCreate': (None, dt_auto_create),
        'bom': open(sbom_path, 'rb')
    }

    if dt_project == "":
        if dt_project_name != "":
            if dt_project_version == "":
               bb.error("DEPENDENCYTRACK_PROJECT_VERSION is mandatory if DEPENDENCYTRACK_PROJECT_NAME is set")
            else:
               files['projectName'] = (None, dt_project_name)
               files['projectVersion'] = (None, dt_project_version)
    else:
        files['project'] = dt_project

    if dt_parent == "":
        if dt_parent_name != "":
            if dt_parent_version == "":
               bb.error("DEPENDENCYTRACK_PARENT_VERSION is mandatory if DEPENDENCYTRACK_PARENT_NAME is set")
            else:
               files['parentName'] = (None, dt_parent_name)
               files['parentVersion'] = (None, dt_parent_version)
    else:
        files['parent'] = dt_parent

    try:
        response = requests.post(dt_url, headers=headers, files=files)
        response.raise_for_status()
    except requests.exceptions.HTTPError as e:
        bb.error(f"Failed to upload SBOM to Dependency Track server at {dt_url}. [HTTP Error] {e}")
    except requests.exceptions.RequestException as e:
        bb.error(f"Failed to upload SBOM to Dependency Track server at {dt_url}. [Error] {e}")
    else:
        bb.debug(2, f"SBOM successfully uploaded to {dt_url}")
}
addhandler do_dependencytrack_upload
do_dependencytrack_upload[eventmask] = "bb.event.BuildCompleted"

def read_sbom(d):
    import json
    from pathlib import Path
    return json.loads(Path(d.getVar("DEPENDENCYTRACK_SBOM")).read_text())

def write_sbom(d, sbom):
    import json
    from pathlib import Path
    Path(d.getVar("DEPENDENCYTRACK_SBOM")).write_text(
        json.dumps(sbom, indent=2)
    )

def get_licenses(d) :
    from pathlib import Path
    import json
    license_expression = d.getVar("LICENSE")
    if license_expression:
        license_json = []
        licenses = license_expression.replace("|", "").replace("&", "").split()
        for license in licenses:
            license_conversion_map = json.loads(d.getVar('DT_LICENSE_CONVERSION_MAP'))
            converted_license = None
            try:
                converted_license =  license_conversion_map[license]
            except Exception as e:
                    pass
            if not converted_license:
                converted_license = license
            # Search for the license in COMMON_LICENSE_DIR and LICENSE_PATH
            for directory in [d.getVar('COMMON_LICENSE_DIR')] + (d.getVar('LICENSE_PATH') or '').split():
                try:
                    with (Path(directory) / converted_license).open(errors="replace") as f:
                        extractedText = f.read()
                        license_data = {
                            "license": {
                                "name" : converted_license,
                                "text": {
                                    "contentType": "text/plain",
                                    "content": extractedText
                                    }
                            }
                        }
                        license_json.append(license_data)
                        break
                except FileNotFoundError:
                    pass
            # license_json.append({"expression" : license_expression})
        return license_json 
    return None

def get_cpe_ids(cve_product, version):
    """
    Get list of CPE identifiers for the given product and version
    """

    version = version.split("+git")[0]

    cpe_ids = []
    for product in cve_product.split():
        # CVE_PRODUCT in recipes may include vendor information for CPE identifiers. If not,
        # use wildcard for vendor.
        if ":" in product:
            vendor, product = product.split(":", 1)
        else:
            vendor = "*"

        cpe_id = 'cpe:2.3:a:{}:{}:{}:*:*:*:*:*:*:*'.format(vendor, product, version)
        cpe_ids.append(type('',(object,),{"cpe": cpe_id, "product": product, "vendor": vendor if vendor != "*" else ""})())

    return cpe_ids
