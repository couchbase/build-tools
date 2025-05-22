from blackduck import Client

class BlackDuckClient(Client):
    """
    A wrapper around the Black Duck API client to provide custom functionality.
    """

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.resources = self.list_resources()

    def _get_by_name(self, resource, name, parent=None):
        """
        Retrieve a resource by its name.

        :param resource: The type of resource to retrieve (e.g., 'project'). Should be singular.
        :param name: The name of the resource to retrieve.
        :return: The resource object if found, None otherwise.
        """
        key = f"{resource}Name" if parent else "name"
        params = {
            'q': [f"name:{name}"]
        }
        things = [t for t in self.get_resource(f"{resource}s", parent, params=params) if t[key] == name]
        if not things:
            return None
        # If there are multiple resources with the same name, raise an error
        assert len(things) == 1, f"There should be exactly one '{resource}' resource named '{name}' (found {len(things)})"
        return things[0]

    def get_project_by_name(self, project_name):
        """
        Retrieve a project by its name.

        :param project_name: The name of the project to retrieve.
        :return: The project object if found, None otherwise.
        """
        return self._get_by_name('project', name=project_name)

    def get_version_by_name(self, project, version_name):
        """
        Retrieve a project version by its name.

        :param project: The project object to retrieve the version from.
        :param version_name: The name of the version to retrieve.
        :return: The version object if found, None otherwise.
        """
        return self._get_by_name('version', parent=project, name=version_name)
